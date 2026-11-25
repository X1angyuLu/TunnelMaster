import Darwin
import Foundation
import TunnelMasterCore

enum SessionError: LocalizedError {
    case unavailablePort
    case invalidEngineConfiguration
    case engineDidNotStart
    case geoIPUnavailable
    case exitUnavailable
    case metricsUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailablePort: return "无法分配本机代理端口。"
        case .invalidEngineConfiguration: return "Mihomo 无法读取生成的规则或 WireGuard 配置。"
        case .engineDidNotStart: return "Mihomo 未能启动本机代理。"
        case .geoIPUnavailable: return "无法下载中国大陆 IP 数据。可以关闭 IP 分流后仅用域名规则。"
        case .exitUnavailable: return "未能验证公网出口。"
        case .metricsUnavailable: return "暂时无法读取流量统计。"
        }
    }
}

struct MihomoMetrics: Sendable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connectionCount: Int
}

extension MihomoMetrics: Decodable {
    private enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try values.decode(Int64.self, forKey: .downloadTotal)
        uploadTotal = try values.decode(Int64.self, forKey: .uploadTotal)
        // Mihomo returns null with no active connections. Count entries without decoding their metadata.
        connectionCount = try values.decodeNil(forKey: .connections)
            ? 0
            : values.nestedUnkeyedContainer(forKey: .connections).count ?? 0
    }
}

enum MacCommand {
    static func capture(_ executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func hasActiveVPN() -> Bool {
        guard let output = try? capture("/usr/sbin/scutil", arguments: ["--nc", "list"]).output else {
            return false
        }
        return output.split(separator: "\n").contains { line in
            line.contains(" VPN (") && (line.contains("(Connected)") || line.contains("(Connecting)"))
        }
    }
}

final class MihomoSession: @unchecked Sendable {
    private let process: Process
    private let home: URL
    private let metricsSocket: URL?
    let port: Int

    var isRunning: Bool { process.isRunning }

    private init(process: Process, home: URL, port: Int, metricsSocket: URL?) {
        self.process = process
        self.home = home
        self.port = port
        self.metricsSocket = metricsSocket
    }

    static var executable: String? {
        ["/opt/homebrew/bin/mihomo", "/usr/local/bin/mihomo"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func start(
        executable: String,
        workDirectory: URL,
        profile: WireGuardProfile,
        rules: DomainRules,
        geoIP: URL?
    ) throws -> MihomoSession {
        let fileManager = FileManager.default
        let home = workDirectory.appendingPathComponent("mihomo-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = home.appendingPathComponent("config.json")
        let metricsSocket = makeMetricsSocketPath()
        var startedProcess: Process?

        do {
            let port = try localPort()
            var database: URL?
            if let geoIP {
                let target = home.appendingPathComponent("Country.mmdb")
                try fileManager.copyItem(at: geoIP, to: target)
                database = target
            }
            let data = try MihomoConfiguration.make(
                profile: profile, rules: rules, port: port, chinaIPDatabasePath: database?.path
            )
            try data.write(to: config, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

            let arguments = ["-d", home.path, "-f", config.path]
            let validator = engine(executable, arguments: arguments + ["-t"], home: home)
            try validator.run()
            validator.waitUntilExit()
            guard validator.terminationStatus == 0 else { throw SessionError.invalidEngineConfiguration }

            let process = engine(executable, arguments: arguments, home: home, metricsSocket: metricsSocket)
            try process.run()
            startedProcess = process
            for _ in 0..<24 where process.isRunning {
                if (try? MacCommand.capture("/usr/bin/nc", arguments: ["-z", "-G", "1", "127.0.0.1", String(port)]).status) == 0,
                   process.isRunning {
                    // Mihomo has loaded the configuration; avoid retaining a second private-key copy.
                    try fileManager.removeItem(at: config)
                    return MihomoSession(process: process, home: home, port: port, metricsSocket: metricsSocket)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            throw SessionError.engineDidNotStart
        } catch {
            if let startedProcess, startedProcess.isRunning {
                startedProcess.terminate()
                startedProcess.waitUntilExit()
            }
            try? fileManager.removeItem(at: home)
            Self.removeMetricsSocketDirectory(for: metricsSocket)
            throw error
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: home)
        Self.removeMetricsSocketDirectory(for: metricsSocket)
    }

    func readMetrics() throws -> MihomoMetrics {
        guard isRunning, let metricsSocket, FileManager.default.fileExists(atPath: metricsSocket.path) else {
            throw SessionError.metricsUnavailable
        }
        let result = try MacCommand.capture("/usr/bin/curl", arguments: [
            "--disable", "--silent", "--fail", "--max-time", "2", "--max-filesize", "8388608",
            "--noproxy", "*", "--unix-socket", metricsSocket.path, "http://localhost/connections",
        ])
        guard result.status == 0 else { throw SessionError.metricsUnavailable }
        let metrics = try JSONDecoder().decode(MihomoMetrics.self, from: Data(result.output.utf8))
        guard metrics.downloadTotal >= 0, metrics.uploadTotal >= 0 else { throw SessionError.metricsUnavailable }
        return metrics
    }

    func checkExit() throws -> String {
        let result = try MacCommand.capture("/usr/bin/curl", arguments: [
            "--silent", "--show-error", "--fail", "--max-time", "10",
            "--proxy", "http://127.0.0.1:\(port)", "--noproxy", "",
            "https://www.cloudflare.com/cdn-cgi/trace",
        ])
        guard result.status == 0,
              let line = result.output.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else {
            throw SessionError.exitUnavailable
        }
        let ip = String(line.dropFirst(3))
        var ipv4 = in_addr(), ipv6 = in6_addr()
        guard inet_pton(AF_INET, ip, &ipv4) == 1 || inet_pton(AF_INET6, ip, &ipv6) == 1 else {
            throw SessionError.exitUnavailable
        }
        return ip
    }

    private static func engine(_ executable: String, arguments: [String], home: URL, metricsSocket: URL? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Mihomo accepts environment-based configuration overrides; do not inherit them.
        var environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        if let metricsSocket {
            environment["CLASH_OVERRIDE_EXTERNAL_CONTROLLER_UNIX"] = metricsSocket.path
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private static func makeMetricsSocketPath() -> URL? {
        // Use a short path for sockaddr_un. The atomically created 0700 directory protects the local API.
        var template = Array("/tmp/tunnelmaster-XXXXXX".utf8CString)
        return template.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress, let path = mkdtemp(base) else { return nil }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("metrics.sock")
        }
    }

    private static func removeMetricsSocketDirectory(for socket: URL?) {
        guard let directory = socket?.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func localPort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SessionError.unavailablePort }
        defer { Darwin.close(socket) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard Darwin.bind(socket, pointer, length) == 0 else { return Int32(-1) }
                return Darwin.getsockname(socket, pointer, &length)
            }
        }
        guard result == 0 else { throw SessionError.unavailablePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
