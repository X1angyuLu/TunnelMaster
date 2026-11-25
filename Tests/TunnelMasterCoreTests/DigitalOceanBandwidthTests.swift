import Foundation
import Testing
@testable import TunnelMasterCore

struct DigitalOceanBandwidthTests {
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

    private func query(_ client: DigitalOceanBandwidthClient) async throws -> DigitalOceanBandwidthReport {
        try await client.report(
            dropletID: "123", token: "fixture-token",
            from: Date(timeIntervalSince1970: 120), until: Date(timeIntervalSince1970: 360)
        )
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
