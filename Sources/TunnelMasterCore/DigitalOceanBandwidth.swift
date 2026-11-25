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
}

public struct DigitalOceanBandwidthReport: Sendable {
    public let inbound: DigitalOceanBandwidthSeries
    public let outbound: DigitalOceanBandwidthSeries
    public let from: Date
    public let until: Date
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
        let enteredID = dropletID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enteredID.utf8.allSatisfy({ (48...57).contains($0) }),
              let identifier = UInt64(enteredID), identifier > 0 else {
            throw DigitalOceanBandwidthError.invalidDropletID
        }
        let authorization = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorization.isEmpty, authorization.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DigitalOceanBandwidthError.invalidToken
        }
        guard from < until,
              let start = Int64(exactly: floor(from.timeIntervalSince1970)), start >= 0,
              let end = Int64(exactly: ceil(until.timeIntervalSince1970)) else {
            throw DigitalOceanBandwidthError.invalidWindow
        }

        let window = DateInterval(start: from, end: until)
        let query = BandwidthQuery(dropletID: String(identifier), start: start, end: end, window: window)
        async let inbound = fetch(query, direction: .inbound, token: authorization)
        async let outbound = fetch(query, direction: .outbound, token: authorization)
        return try await DigitalOceanBandwidthReport(inbound: inbound, outbound: outbound, from: from, until: until)
    }

    private func fetch(_ query: BandwidthQuery, direction: Direction, token: String) async throws
        -> DigitalOceanBandwidthSeries {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.digitalocean.com"
        url.path = "/v2/monitoring/metrics/droplet/bandwidth"
        url.queryItems = [
            URLQueryItem(name: "host_id", value: query.dropletID),
            URLQueryItem(name: "interface", value: "public"),
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "start", value: String(query.start)),
            URLQueryItem(name: "end", value: String(query.end))
        ]
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
        return DigitalOceanBandwidthSeries(samples: [], estimatedBytes: nil, coveredSeconds: 0, peakMbps: nil)
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
            var bytes = 0.0
            var coverage = 0.0
            if !intervals.isEmpty {
                let cadence = intervals[(intervals.count - 1) / 2]
                // Estimate only between nearby samples. A missing or nonfinite reading breaks coverage.
                let maxGap = min(cadence * 1.5, 30 * 60)
                for (first, second) in pairs {
                    let interval = second.timestamp - first.timestamp
                    let start = max(first.timestamp, from)
                    let end = min(second.timestamp, until)
                    guard interval <= maxGap, end > start, let initial = first.mbps, let next = second.mbps else { continue }
                    let midpoint = ((start - first.timestamp) + (end - first.timestamp)) / (2 * interval)
                    let averageMbps = initial * (1 - midpoint) + next * midpoint
                    bytes += averageMbps * 125_000 * (end - start)
                    coverage += end - start
                }
            }
            return DigitalOceanBandwidthSeries(
                samples: samples,
                estimatedBytes: coverage > 0 ? Int64(exactly: bytes.rounded()) : nil,
                coveredSeconds: coverage,
                peakMbps: samples.map(\.mbps).max()
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
