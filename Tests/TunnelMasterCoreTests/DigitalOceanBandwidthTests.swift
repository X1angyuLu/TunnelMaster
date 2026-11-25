import Foundation
import Testing
@testable import TunnelMasterCore

struct DigitalOceanBandwidthTests {
    @Test func listsDropletPagesWithoutFollowingProviderLinks() async throws {
        let client = dropletClient { page in
            switch page {
            case 1:
                return (200, """
                {"droplets":[{"id":42,"name":"Alpha","region":{"slug":"sfo3"},"status":"active"}],
                 "links":{"pages":{"next":"https://untrusted.invalid/other?per_page=50&page=87"}}}
                """)
            case 2:
                return (200, """
                {"droplets":[{"id":42,"name":"Alpha","region":{"slug":"sfo3"}},
                             {"id":43,"name":"Beta","region":{"slug":"nyc3"}}],
                 "links":{"pages":{"prev":"https://api.digitalocean.com/v2/droplets?page=1"}}}
                """)
            default:
                Issue.record("Unexpected Droplet page request")
                return (400, "{}")
            }
        }
        let droplets = try await client.droplets(token: " fixture-token ")
        #expect(droplets.map(\.id) == ["42", "43"])
        #expect(droplets.map(\.name) == ["Alpha", "Beta"])
        #expect(droplets.map(\.region) == ["sfo3", "nyc3"])
        #expect(droplets.map(\.status) == ["active", nil])
    }

    @Test func usesDropletMetadataWhenPageLinksAreAbsent() async throws {
        let client = dropletClient { page in
            let ids = page == 1 ? 1...200 : 201...201
            let elements = ids.map { """
            {"id":\($0),"name":"Fixture","region":{"slug":"sfo3"}}
            """ }
            return (200, """
            {"droplets":[\(elements.joined(separator: ","))],"meta":{"total":201}}
            """)
        }
        let droplets = try await client.droplets(token: "fixture-token")
        #expect(droplets.count == 201)
        #expect(droplets.last?.id == "201")
    }

    @Test func rejectsRepeatedDropletPagesAndPropagatesUnauthorized() async {
        let repeating = dropletClient { _ in (200, """
        {"droplets":[{"id":42,"name":"Alpha","region":{"slug":"sfo3"}}],
         "links":{"pages":{"next":"https://api.digitalocean.com/v2/droplets?page=2"}}}
        """) }
        await #expect(throws: DigitalOceanBandwidthError.invalidResponse) {
            try await repeating.droplets(token: "fixture-token")
        }
        let unauthorized = dropletClient { _ in (403, "{}") }
        await #expect(throws: DigitalOceanBandwidthError.unauthorized) {
            try await unauthorized.droplets(token: "fixture-token")
        }
    }

    @Test func requestsBothPublicDirectionsAndClipsEstimatesToMeasuredIntervals() async throws {
        let client = stub { request, direction in
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "api.digitalocean.com")
            #expect(url.path == "/v2/monitoring/metrics/droplet/bandwidth")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "host_id", value: "123")))
            #expect(query.contains(URLQueryItem(name: "interface", value: "public")))
            #expect(query.contains(URLQueryItem(name: "start", value: "120")))
            #expect(query.contains(URLQueryItem(name: "end", value: "920")))
            #expect(!url.absoluteString.contains("fixture-token"))
            if direction == "outbound" { return Self.matrix() }
            return Self.matrix(Self.series(direction, """
            [[900,"10"],[100,"2"],[160,"4"],[238,"8"],[360,"NaN"],[420,"0"],[480,"0"],[960,"18"]]
            """))
        }
        let from = Date(timeIntervalSince1970: 120)
        let until = Date(timeIntervalSince1970: 920)
        let report = try await client.report(dropletID: " 123 ", token: " fixture-token ", from: from, until: until)

        #expect(report.from == from)
        #expect(report.until == until)
        #expect(report.inbound.samples.map { $0.timestamp.timeIntervalSince1970 } == [160, 238, 420, 480, 900])
        #expect(report.inbound.estimatedBytes == 103_500_000)
        #expect(report.inbound.coveredSeconds == 198)
        #expect(report.inbound.peakMbps == 10)
        #expect(report.outbound.samples.isEmpty)
        #expect(report.outbound.coveredSeconds == 0)
        #expect(report.outbound.estimatedBytes == nil)
        #expect(report.outbound.peakMbps == nil)
    }

    @Test func distinguishesMeasuredZeroFromIsolatedAndMissingSamples() async throws {
        let client = stub { _, direction in
            let samples = direction == "inbound"
                ? "[[120,\"0\"],[180,\"0\"],[240,\"NaN\"],[300,\"-1\"],[360,\"+Inf\"]]"
                : "[[120,\"4\"],[120,\"4\"],[180,\"NaN\"]]"
            return Self.matrix(Self.series(direction, samples))
        }
        let report = try await query(client)
        #expect(report.inbound.estimatedBytes == 0)
        #expect(report.inbound.coveredSeconds == 60)
        #expect(report.outbound.samples.count == 1)
        #expect(report.outbound.estimatedBytes == nil)
        #expect(report.outbound.peakMbps == 4)
    }

    @Test func subrangeEstimatesReconcileWithTotalsAcrossMeasuredAndMissingHours() async throws {
        let client = stub { _, direction in
            let samples = """
            [[3480,"8"],[3540,"8"],[3600,"8"],[3660,"8"],[3720,"NaN"],[7200,"0"],[7260,"0"],[7320,"NaN"]]
            """
            return Self.matrix(Self.series(direction, samples))
        }
        let window = interval(3500, 7400)
        let report = try await client.report(
            dropletID: "123", token: "fixture-token", from: window.start, until: window.end
        )
        let series = report.inbound
        let hours = [interval(0, 3600), interval(3600, 7200), interval(7200, 10800)]
        let estimates = hours.map { series.estimate(in: $0) }
        #expect(estimates.map(\.estimatedBytes) == [100_000_000, 60_000_000, 0])
        #expect(estimates.map(\.coveredSeconds) == [100, 60, 60])
        #expect(series.estimate(in: interval(3660, 7200)).estimatedBytes == nil)
        #expect(series.estimate(in: interval(3660, 7200)).coveredSeconds == 0)
        #expect(estimates.compactMap(\.estimatedBytes).reduce(0, +) == Double(series.estimatedBytes ?? -1))
        #expect(estimates.map(\.coveredSeconds).reduce(0, +) == series.coveredSeconds)
    }

    @Test func rejectsUnexpectedOrMismatchedSeries() async {
        let multiple = stub { _, direction in
            let metric = Self.series(direction, "[]")
            return Self.matrix(metric + "," + metric)
        }
        await #expect(throws: DigitalOceanBandwidthError.invalidResponse) {
            try await query(multiple)
        }
        let wrongHost = stub { _, direction in Self.matrix(Self.series(direction, "[]", host: "124")) }
        await #expect(throws: DigitalOceanBandwidthError.invalidResponse) {
            try await query(wrongHost)
        }
    }

    @Test func distinguishesAuthenticationRateLimitAndUnexpectedHTTPStatuses() async {
        let unauthorized = stub(status: 403) { _, _ in "secret provider response" }
        await #expect(throws: DigitalOceanBandwidthError.unauthorized) {
            try await query(unauthorized)
        }
        let constrained = stub(status: 429) { _, _ in "" }
        await #expect(throws: DigitalOceanBandwidthError.rateLimited) {
            try await query(constrained)
        }
        let redirected = stub(status: 302) { _, _ in "" }
        await #expect(throws: DigitalOceanBandwidthError.httpStatus(302)) {
            try await query(redirected)
        }
    }

    @Test func monthUsesCreationDateAndSignedProjectedRemainder() async throws {
        let created = try Date.ISO8601FormatStyle().parse("2026-11-26T11:00:00Z")
        let now = created.addingTimeInterval(3600)
        let client = monthlyClient(metadata: """
        {"droplet":{"id":123,"created_at":"2026-11-26T11:00:00Z","size":{"slug":"s-1vcpu-1gb","transfer":1}}}
        """) { start, end in
            #expect(start == Int(created.timeIntervalSince1970))
            #expect(end == Int(now.timeIntervalSince1970))
            return Self.monthlySamples(start: start, end: end, mbps: 1000, cadence: 600)
        }
        let usage = try await client.monthlyTransfer(dropletID: "123", token: "fixture-token", now: now)
        #expect(usage.monthStart == (try Date.ISO8601FormatStyle().parse("2026-11-01T00:00:00Z")))
        #expect(usage.asOf == now)
        #expect(usage.coverage == 1)
        #expect(usage.planGiB == 1000)
        let accrued = try #require(usage.accruedGiB)
        let projected = try #require(usage.projectedAllowanceGiB)
        let outbound = try #require(usage.outboundGiB)
        let remaining = try #require(usage.remainingGiB)
        #expect(abs(accrued - (1000.0 / 672)) < 0.001)
        #expect(abs(projected - (1000.0 * 109 / 672)) < 0.001)
        #expect(abs(outbound - (450_000_000_000.0 / 1_073_741_824)) < 0.001)
        #expect(remaining == projected - outbound && remaining < 0)
    }

    @Test func monthClipsOverlappingSlicesAndReportsPartialCoverage() async throws {
        let monthStart = try Date.ISO8601FormatStyle().parse("2026-11-01T00:00:00Z")
        let now = monthStart.addingTimeInterval(21 * 86_400)
        let missingSlice = Int(monthStart.timeIntervalSince1970) + 6 * 86_400 - 1_800
        let client = monthlyClient(metadata: """
        {"droplet":{"id":123,"created_at":"2026-10-01T00:00:00Z","size":{"slug":"s-1vcpu-1gb","transfer":1}}}
        """) { start, end in
            #expect(end - start <= 7 * 86_400)
            if start == missingSlice { return Self.matrix() }
            return Self.monthlySamples(start: start, end: end, mbps: 1, cadence: 900)
        }
        let usage = try await client.monthlyTransfer(dropletID: "123", token: "fixture-token", now: now)
        #expect(usage.coverage == 15.0 / 21)
        #expect(usage.outboundGiB == (15.0 * 86_400 * 125_000 / 1_073_741_824))
        #expect(usage.accruedGiB == 750)
        #expect(usage.projectedAllowanceGiB == 1000)
        #expect(usage.remainingGiB == nil)
    }

    @Test func unavailableMetadataDoesNotHideUsageAndRolloverDoesNotQueryEmptyRange() async throws {
        let monthStart = try Date.ISO8601FormatStyle().parse("2026-12-01T00:00:00Z")
        let client = monthlyClient(status: 403, metadata: "{}") { start, end in
            #expect(start == Int(monthStart.timeIntervalSince1970))
            #expect(end > start)
            return Self.monthlySamples(start: start, end: end, mbps: 0, cadence: 600)
        }
        let usage = try await client.monthlyTransfer(
            dropletID: "123", token: "fixture-token", now: monthStart.addingTimeInterval(3600)
        )
        #expect(usage.outboundGiB == 0)
        #expect(usage.coverage == 1)
        #expect(usage.planGiB == nil && usage.remainingGiB == nil && usage.projectedAllowanceGiB == nil)
        let rollover = try await client.monthlyTransfer(dropletID: "123", token: "fixture-token", now: monthStart)
        #expect(rollover.outboundGiB == nil && rollover.coverage == nil)
    }

    @Test func v5MonthAllowanceDoesNotCapAtTwentyEightDays() async throws {
        let client = monthlyClient(metadata: """
        {"droplet":{"id":123,"created_at":"2026-10-01T00:00:00.000Z","size":{"slug":"g5-1vcpu-8gb","transfer":2}}}
        """) { _, _ in Self.matrix() }
        let now = try Date.ISO8601FormatStyle().parse("2026-12-31T00:00:00Z")
        let usage = try await client.monthlyTransfer(dropletID: "123", token: "fixture-token", now: now)
        #expect(usage.planGiB == 2000)
        #expect(usage.accruedGiB == 2000.0 * (30.0 / 28))
        #expect(usage.projectedAllowanceGiB == 2000.0 * (31.0 / 28))
        #expect(usage.outboundGiB == nil && usage.coverage == 0 && usage.remainingGiB == nil)
    }

    private func query(_ client: DigitalOceanBandwidthClient) async throws -> DigitalOceanBandwidthReport {
        try await client.report(
            dropletID: "123", token: "fixture-token",
            from: Date(timeIntervalSince1970: 120), until: Date(timeIntervalSince1970: 360)
        )
    }

    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    private func dropletClient(
        responder: @escaping @Sendable (Int) -> (Int, String)
    ) -> DigitalOceanBandwidthClient {
        DigitalOceanBandwidthClient(transport: { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https" && url.host == "api.digitalocean.com" && url.path == "/v2/droplets")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.contains(URLQueryItem(name: "per_page", value: "200")))
            let page = try #require(items.first(where: { $0.name == "page" })?.value.flatMap(Int.init))
            let (status, body) = responder(page)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        })
    }

    private func stub(
        status: Int = 200,
        responder: @escaping @Sendable (URLRequest, String) throws -> String
    ) -> DigitalOceanBandwidthClient {
        DigitalOceanBandwidthClient(transport: { request in
            let url = try #require(request.url)
            let direction = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "direction" })?.value)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(try responder(request, direction).utf8), response)
        })
    }

    private func monthlyClient(
        status: Int = 200, metadata: String, samples: @escaping @Sendable (Int, Int) -> String
    ) -> DigitalOceanBandwidthClient {
        DigitalOceanBandwidthClient(transport: { request in
            let url = try #require(request.url)
            #expect(url.host == "api.digitalocean.com" && url.scheme == "https")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let isMetadata = url.path == "/v2/droplets/123"
            let body: String
            if isMetadata {
                body = metadata
            } else {
                #expect(url.path == "/v2/monitoring/metrics/droplet/bandwidth")
                let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                #expect(params["interface"] == "public" && params["direction"] == "outbound" && params["host_id"] == "123")
                let start = try #require(params["start"].flatMap(Int.init))
                let end = try #require(params["end"].flatMap(Int.init))
                body = samples(start, end)
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: isMetadata ? status : 200, httpVersion: nil, headerFields: nil
            ))
            return (Data(body.utf8), response)
        })
    }

    private static func monthlySamples(start: Int, end: Int, mbps: Int, cadence: Int) -> String {
        let points = stride(from: start, through: end, by: cadence).map { "[\($0),\"\(mbps)\"]" }
        return matrix(series("outbound", "[\(points.joined(separator: ","))]"))
    }

    private static func matrix(_ results: String = "") -> String {
        """
        {"status":"success","data":{"resultType":"matrix","result":[\(results)]}}
        """
    }

    private static func series(_ direction: String, _ samples: String, host: String = "123") -> String {
        """
        {"metric":{"direction":"\(direction)","host_id":"\(host)","interface":"public"},"values":\(samples)}
        """
    }
}
