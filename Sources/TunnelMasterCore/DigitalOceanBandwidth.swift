import Foundation

public struct DigitalOceanBandwidthSample: Sendable, Identifiable {
    public let timestamp: Date
    public let mbps: Double
    public var id: Date { timestamp }
}

public struct DigitalOceanBandwidthSeries: Sendable {
    public let samples: [DigitalOceanBandwidthSample]
    public let estimatedBytes: Int64?
    public let coveredSeconds: TimeInterval
    public let peakMbps: Double?

    private let window: DateInterval
    private let observations: [BandwidthObservation]

    fileprivate init(samples: [DigitalOceanBandwidthSample], observations: [BandwidthObservation], window: DateInterval) {
        self.samples = samples
        self.window = window
        self.observations = observations
        let estimate = Self.estimate(in: window, using: observations)
        self.estimatedBytes = estimate.estimatedBytes.flatMap { Int64(exactly: $0.rounded()) }
        self.coveredSeconds = estimate.coveredSeconds
        self.peakMbps = samples.map(\.mbps).max()
    }

    /// Estimates bytes only from observed intervals that overlap both the query and the requested subrange.
    public func estimate(in interval: DateInterval) -> (estimatedBytes: Double?, coveredSeconds: TimeInterval) {
        guard let overlap = window.intersection(with: interval) else { return (nil, 0) }
        return Self.estimate(in: overlap, using: observations)
    }

    private static func estimate(in interval: DateInterval, using observations: [BandwidthObservation])
        -> (estimatedBytes: Double?, coveredSeconds: TimeInterval) {
        let from = interval.start.timeIntervalSince1970
        let until = interval.end.timeIntervalSince1970
        var bytes = 0.0
        var coverage = 0.0
        for observation in observations {
            let start = max(observation.start, from)
            let end = min(observation.end, until)
            guard start < end else { continue }
            let midpoint = ((start - observation.start) + (end - observation.start))
                / (2 * (observation.end - observation.start))
            let averageMbps = observation.initialMbps * (1 - midpoint) + observation.finalMbps * midpoint
            bytes += averageMbps * 125_000 * (end - start)
            coverage += end - start
        }
        return (coverage > 0 && bytes.isFinite ? bytes : nil, coverage)
    }
}

fileprivate struct BandwidthObservation: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let initialMbps: Double
    let finalMbps: Double
}

public struct DigitalOceanBandwidthReport: Sendable {
    public let inbound: DigitalOceanBandwidthSeries
    public let outbound: DigitalOceanBandwidthSeries
    public let from: Date
    public let until: Date
}

public struct DigitalOceanMonthlyTransfer: Sendable {
    public let monthStart: Date
    public let asOf: Date
    public let outboundGiB: Double?
    public let coverage: Double?
    public let planGiB: Double?
    public let accruedGiB: Double?
    /// Projected month-end allowance less observed outbound usage, when coverage is sufficient.
    public let remainingGiB: Double?
    public let projectedAllowanceGiB: Double?
}

public enum DigitalOceanBandwidthError: LocalizedError, Equatable, Sendable {
    case invalidDropletID
    case invalidToken
    case invalidWindow
    case unauthorized
    case rateLimited
    case networkUnavailable
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidDropletID: "请输入有效的 Droplet ID。"
        case .invalidToken: "请输入有效的 DigitalOcean API 令牌。"
        case .invalidWindow: "请选择有效的统计时间范围。"
        case .unauthorized: "DigitalOcean 未授权访问。请检查令牌是否有效并具有 monitoring:read 权限。"
        case .rateLimited: "DigitalOcean 请求过于频繁。请稍后重试。"
        case .networkUnavailable: "无法连接 DigitalOcean。请检查网络后重试。"
        case .httpStatus(let status): "DigitalOcean 查询失败（HTTP \(status)）。"
        case .invalidResponse: "DigitalOcean 返回了无法识别的带宽数据。"
        }
    }
}

public struct DigitalOceanBandwidthClient: Sendable {
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    public init() {
        self.init(transport: { try await Self.session.data(for: $0) })
    }

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.transport = transport
    }

    public func report(dropletID: String, token: String, from: Date, until: Date) async throws -> DigitalOceanBandwidthReport {
        let credential = try Self.credentials(dropletID: dropletID, token: token)
        let query = try BandwidthQuery(dropletID: credential.id, from: from, until: until)
        async let inbound = fetch(query, direction: .inbound, token: credential.token)
        async let outbound = fetch(query, direction: .outbound, token: credential.token)
        return try await DigitalOceanBandwidthReport(inbound: inbound, outbound: outbound, from: from, until: until)
    }

    public func monthlyTransfer(dropletID: String, token: String, now: Date = .now) async throws
        -> DigitalOceanMonthlyTransfer {
        let credential = try Self.credentials(dropletID: dropletID, token: token)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard now.timeIntervalSince1970 >= 0, Int64(exactly: ceil(now.timeIntervalSince1970)) != nil,
              let month = calendar.dateInterval(of: .month, for: now) else {
            throw DigitalOceanBandwidthError.invalidWindow
        }

        let metadata: DropletMetadata?
        do {
            metadata = try await dropletMetadata(id: credential.id, token: credential.token, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            metadata = nil
        }
        let first = max(month.start, metadata?.createdAt ?? month.start)
        let elapsed = now.timeIntervalSince(first)
        var cursor = first
        var bytes = 0.0
        var coveredSeconds = 0.0
        while cursor < now {
            try Task.checkCancellation()
            let end = min(now, cursor.addingTimeInterval(6 * 86_400))
            // Overlap neighboring requests so a slice boundary does not discard observed rates.
            // Integrate the nonoverlapping slices separately so no time is counted twice.
            let query = try BandwidthQuery(
                dropletID: credential.id,
                from: max(first, cursor.addingTimeInterval(-1_800)),
                until: min(now, end.addingTimeInterval(1_800))
            )
            let series = try await fetch(query, direction: .outbound, token: credential.token)
            let estimate = series.estimate(in: DateInterval(start: cursor, end: end))
            if let amount = estimate.estimatedBytes {
                bytes += amount
                coveredSeconds += estimate.coveredSeconds
            }
            cursor = end
        }
        try Task.checkCancellation()
        let outboundGiB = coveredSeconds > 0 && bytes.isFinite ? bytes / 1_073_741_824 : nil
        let coverage = elapsed > 0 ? min(1, coveredSeconds / elapsed) : nil
        let accrued = metadata?.plan?.allowance(during: elapsed)
        let projected = metadata?.plan?.allowance(during: month.end.timeIntervalSince(first))
        let remaining: Double?
        if let outboundGiB, let coverage, coverage >= 0.95, let projected {
            remaining = projected - outboundGiB
        } else {
            remaining = nil
        }
        return DigitalOceanMonthlyTransfer(
            monthStart: month.start, asOf: now, outboundGiB: outboundGiB, coverage: coverage,
            planGiB: metadata?.plan?.includedGiB, accruedGiB: accrued, remainingGiB: remaining,
            projectedAllowanceGiB: projected
        )
    }

    private static func credentials(dropletID: String, token: String) throws -> (id: String, token: String) {
        let enteredID = dropletID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enteredID.utf8.allSatisfy({ (48...57).contains($0) }),
              let identifier = UInt64(enteredID), identifier > 0 else {
            throw DigitalOceanBandwidthError.invalidDropletID
        }
        let authorization = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorization.isEmpty, authorization.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DigitalOceanBandwidthError.invalidToken
        }
        return (String(identifier), authorization)
    }

    private func request(path: String, queryItems: [URLQueryItem]? = nil, token: String) async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.digitalocean.com"
        url.path = path
        url.queryItems = queryItems
        guard let endpoint = url.url else { throw DigitalOceanBandwidthError.invalidWindow }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DigitalOceanBandwidthError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw DigitalOceanBandwidthError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw DigitalOceanBandwidthError.unauthorized
        case 429: throw DigitalOceanBandwidthError.rateLimited
        default: throw DigitalOceanBandwidthError.httpStatus(http.statusCode)
        }
        return data
    }

    private func fetch(_ query: BandwidthQuery, direction: Direction, token: String) async throws
        -> DigitalOceanBandwidthSeries {
        let data = try await request(path: "/v2/monitoring/metrics/droplet/bandwidth", queryItems: [
            URLQueryItem(name: "host_id", value: query.dropletID),
            URLQueryItem(name: "interface", value: "public"),
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "start", value: String(query.start)),
            URLQueryItem(name: "end", value: String(query.end))
        ], token: token)
        guard let matrix = try? JSONDecoder().decode(BandwidthResponse.self, from: data),
              matrix.status == "success", matrix.data.resultType == "matrix",
              matrix.data.result.count <= 1 else {
            throw DigitalOceanBandwidthError.invalidResponse
        }
        if let result = matrix.data.result.first {
            guard result.metric["host_id"] == query.dropletID,
                  result.metric["interface"] == "public", result.metric["direction"] == direction.rawValue else {
                throw DigitalOceanBandwidthError.invalidResponse
            }
            return try result.series(in: query.window)
        }
        return DigitalOceanBandwidthSeries(samples: [], observations: [], window: query.window)
    }

    private func dropletMetadata(id: String, token: String, now: Date) async throws -> DropletMetadata {
        let data = try await request(path: "/v2/droplets/\(id)", token: token)
        guard let detail = try? JSONDecoder().decode(DropletResponse.self, from: data).droplet,
              String(detail.id) == id,
              let createdAt = (try? Date.ISO8601FormatStyle().parse(detail.createdAt))
                ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(detail.createdAt)),
              createdAt <= now else {
            throw DigitalOceanBandwidthError.invalidResponse
        }
        let plan = detail.size.flatMap { size -> DropletMetadata.Plan? in
            // DigitalOcean plan tables express an advertised 1 TB transfer allotment as 1,000 GiB.
            let includedGiB = size.transfer * 1_000
            guard !size.slug.isEmpty, includedGiB.isFinite, includedGiB >= 0 else { return nil }
            return DropletMetadata.Plan(includedGiB: includedGiB, uncapped: size.slug.hasPrefix("s5-") || size.slug.hasPrefix("g5-"))
        }
        return DropletMetadata(createdAt: createdAt, plan: plan)
    }
}

private enum Direction: String, Sendable {
    case inbound, outbound
}

private struct BandwidthQuery: Sendable {
    let dropletID: String
    let start: Int64
    let end: Int64
    let window: DateInterval

    init(dropletID: String, from: Date, until: Date) throws {
        guard from < until,
              let start = Int64(exactly: floor(from.timeIntervalSince1970)), start >= 0,
              let end = Int64(exactly: ceil(until.timeIntervalSince1970)) else {
            throw DigitalOceanBandwidthError.invalidWindow
        }
        self.dropletID = dropletID
        self.start = start
        self.end = end
        self.window = DateInterval(start: from, end: until)
    }
}

private struct DropletResponse: Decodable {
    struct Droplet: Decodable {
        struct Size: Decodable {
            let slug: String
            let transfer: Double
        }

        let id: UInt64
        let createdAt: String
        let size: Size?

        enum CodingKeys: String, CodingKey {
            case id, size
            case createdAt = "created_at"
        }
    }

    let droplet: Droplet
}

private struct DropletMetadata {
    struct Plan {
        let includedGiB: Double
        let uncapped: Bool

        func allowance(during seconds: TimeInterval) -> Double {
            let ratio = seconds / (28 * 86_400)
            return includedGiB * (uncapped ? ratio : min(1, ratio))
        }
    }

    let createdAt: Date
    let plan: Plan?
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct BandwidthResponse: Decodable {
    struct Matrix: Decodable {
        let resultType: String
        let result: [Metric]
    }

    struct Metric: Decodable {
        let metric: [String: String]
        let values: [Point]

        func series(in window: DateInterval) throws -> DigitalOceanBandwidthSeries {
            var readings: [TimeInterval: Point] = [:]
            for point in values {
                if let previous = readings[point.timestamp]?.mbps, let current = point.mbps, previous != current {
                    throw DigitalOceanBandwidthError.invalidResponse
                }
                if readings[point.timestamp]?.mbps == nil { readings[point.timestamp] = point }
            }

            let from = window.start.timeIntervalSince1970
            let until = window.end.timeIntervalSince1970
            let points = readings.values.sorted(by: { $0.timestamp < $1.timestamp })
            let samples = points.compactMap { point -> DigitalOceanBandwidthSample? in
                guard point.timestamp >= from, point.timestamp <= until, let rate = point.mbps else { return nil }
                return DigitalOceanBandwidthSample(timestamp: Date(timeIntervalSince1970: point.timestamp), mbps: rate)
            }
            let pairs = zip(points, points.dropFirst())
            let intervals = pairs.map { $1.timestamp - $0.timestamp }.sorted()
            guard !intervals.isEmpty else {
                return DigitalOceanBandwidthSeries(samples: samples, observations: [], window: window)
            }
            let cadence = intervals[(intervals.count - 1) / 2]
            // Estimate only between nearby samples. A missing or nonfinite reading breaks coverage.
            let maxGap = min(cadence * 1.5, 30 * 60)
            let observations = pairs.compactMap { first, second -> BandwidthObservation? in
                guard second.timestamp - first.timestamp <= maxGap, first.timestamp < until, second.timestamp > from,
                      let initial = first.mbps, let next = second.mbps else { return nil }
                return BandwidthObservation(
                    start: first.timestamp, end: second.timestamp, initialMbps: initial, finalMbps: next
                )
            }
            return DigitalOceanBandwidthSeries(
                samples: samples, observations: observations, window: window
            )
        }
    }

    struct Point: Decodable {
        let timestamp: TimeInterval
        let mbps: Double?

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            timestamp = try pair.decode(TimeInterval.self)
            guard timestamp.isFinite else { throw DigitalOceanBandwidthError.invalidResponse }
            let value = try pair.decode(String.self)
            if let rate = Double(value), rate.isFinite, rate >= 0 {
                mbps = rate
            } else {
                mbps = nil
            }
        }
    }

    let status: String
    let data: Matrix
}
