import CryptoKit
import Darwin
import Foundation
import Security
import SystemConfiguration

/// Owns the HTTP, HTTPS and SOCKS proxy settings of the physical service that
/// provides the default route when rule mode starts.
public struct SystemProxyController: Sendable {
    private let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func hasSavedState() -> Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
    }

    public func appliesToPrimaryService() -> Bool {
        guard let journal = try? read(), let primary = try? Self.primaryServiceID() else {
            return false
        }
        return journal.serviceID == primary
    }

    public func hasActiveProxy() -> Bool {
        guard let active = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return Self.hasEnabledProxy(in: active)
    }

    static func hasEnabledProxy(in configuration: [String: Any]) -> Bool {
        ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains {
            (configuration[$0] as? NSNumber)?.boolValue == true
        }
    }

    public func ownsActiveProxy(port: Int) -> Bool {
        guard let journal = try? read(), journal.port == port, appliesToPrimaryService(),
              let active = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return ["HTTP", "HTTPS", "SOCKS"].allSatisfy { protocolName in
            active["\(protocolName)Enable"] as? Int == 1 &&
                active["\(protocolName)Proxy"] as? String == "127.0.0.1" &&
                active["\(protocolName)Port"] as? Int == port
        }
    }

    public func enable(port: Int) throws {
        guard (1024...65535).contains(port) else {
            throw ProxyError.invalidPort
        }

        try Self.withPreferences { preferences in
            guard !hasSavedState() else {
                throw ProxyError.pendingRecovery
            }
            let serviceID = try Self.primaryServiceID()
            guard let proxy = Self.proxyProtocol(preferences, serviceID: serviceID) else {
                throw ProxyError.noUsableService
            }

            let previous = Self.configuration(proxy)
            if SCNetworkProtocolGetEnabled(proxy), Self.hasEnabledProxy(in: previous) {
                throw ProxyError.activeProxy
            }
            let journal = try ProxyJournal(
                serviceID: serviceID,
                port: port,
                previousEnabled: SCNetworkProtocolGetEnabled(proxy),
                previous: previous
            )
            var updated = previous
            for (key, value) in journal.installedValues {
                updated[key] = value.unboxed
            }

            try save(journal)
            guard SCNetworkProtocolSetConfiguration(proxy, updated as CFDictionary),
                  SCNetworkProtocolSetEnabled(proxy, true),
                  SCPreferencesCommitChanges(preferences) else {
                throw ProxyError.systemConfiguration
            }
            guard SCPreferencesApplyChanges(preferences) else {
                // Preferences reached disk. Roll back while still holding the
                // lock and retain the journal if applying the rollback fails.
                if SCNetworkProtocolSetConfiguration(proxy, previous as CFDictionary),
                   SCNetworkProtocolSetEnabled(proxy, journal.previousEnabled),
                   SCPreferencesCommitChanges(preferences),
                   SCPreferencesApplyChanges(preferences) {
                    try? FileManager.default.removeItem(at: stateURL)
                }
                throw ProxyError.systemConfiguration
            }
        }
    }

    public func disable() throws {
        guard hasSavedState() else { return }

        try Self.withPreferences { preferences in
            guard hasSavedState() else { return }
            let journal = try read()
            guard let proxy = Self.proxyProtocol(preferences, serviceID: journal.serviceID) else {
                // A deleted service has no proxy configuration to restore.
                try FileManager.default.removeItem(at: stateURL)
                return
            }

            let restored = try journal.restoration(
                current: Self.configuration(proxy),
                enabled: SCNetworkProtocolGetEnabled(proxy)
            )
            if restored.changed {
                guard SCNetworkProtocolSetConfiguration(proxy, restored.values as CFDictionary),
                      SCNetworkProtocolSetEnabled(proxy, restored.enabled),
                      SCPreferencesCommitChanges(preferences) else {
                    throw ProxyError.systemConfiguration
                }
            }
            // If a previous attempt already committed the rollback, still
            // apply it before discarding the recovery data.
            guard SCPreferencesApplyChanges(preferences) else {
                throw ProxyError.systemConfiguration
            }
            try FileManager.default.removeItem(at: stateURL)
        }
    }

    private static func primaryServiceID() throws -> String {
        for family in [kSCEntNetIPv4, kSCEntNetIPv6] {
            let key = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, family)
            let state = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
            if let serviceID = state?[kSCDynamicStorePropNetPrimaryService as String] as? String,
               !serviceID.isEmpty {
                return serviceID
            }
        }
        throw ProxyError.noUsableService
    }

    private static func proxyProtocol(_ preferences: SCPreferences, serviceID: String) -> SCNetworkProtocol? {
        guard let service = SCNetworkServiceCopy(preferences, serviceID as CFString) else { return nil }
        return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
    }

    private static func configuration(_ proxy: SCNetworkProtocol) -> [String: Any] {
        SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:]
    }

    private static func withPreferences(_ body: (SCPreferences) throws -> Void) throws {
        var authorization: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights], &authorization)
        guard status == errAuthorizationSuccess, let authorization else {
            throw ProxyError.authorization
        }
        defer { AuthorizationFree(authorization, []) }

        guard let preferences = SCPreferencesCreateWithAuthorization(
            nil, "TunnelMaster" as CFString, nil, authorization
        ), SCPreferencesLock(preferences, false) else {
            throw ProxyError.systemConfiguration
        }
        defer { SCPreferencesUnlock(preferences) }
        try body(preferences)
    }

    private func save(_ journal: ProxyJournal) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(journal)
        let temp = directory.appendingPathComponent(".proxy-\(UUID().uuidString)")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProxyError.cannotSaveState }
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        try FileManager.default.moveItem(at: temp, to: stateURL)
    }

    private func read() throws -> ProxyJournal {
        let journal = try PropertyListDecoder().decode(ProxyJournal.self, from: Data(contentsOf: stateURL))
        guard journal.version == 1, (1024...65535).contains(journal.port) else {
            throw ProxyError.invalidState
        }
        return journal
    }
}

/// Each row is restored as a unit so that changes by another proxy manager
/// cannot be mixed with the previous host, port, or enabled flag.
struct ProxyJournal: Codable {
    let version: Int
    let serviceID: String
    let port: Int
    let previousEnabled: Bool
    private let previousValues: [String: ProxyValue]
    private let previousGuards: [Data]

    private static let groups = [
        ["HTTPEnable", "HTTPProxy", "HTTPPort"],
        ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"],
        ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"],
        ["ProxyAutoConfigEnable"],
        ["ProxyAutoDiscoveryEnable"]
    ]
    private static let guards = [
        ["HTTPUser"], ["HTTPSUser"], ["SOCKSUser"],
        ["ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"], []
    ]

    init(serviceID: String, port: Int, previousEnabled: Bool, previous: [String: Any]) throws {
        for key in ["HTTPUser", "HTTPSUser", "SOCKSUser"] {
            if let user = previous[key] as? String, !user.isEmpty {
                throw ProxyError.authenticatedProxy
            }
        }
        self.version = 1
        self.serviceID = serviceID
        self.port = port
        self.previousEnabled = previousEnabled
        self.previousValues = try Self.values(for: Self.groups.flatMap { $0 }, in: previous)
        self.previousGuards = Self.guards.map { Self.fingerprint(keys: $0, in: previous) }
    }

    fileprivate var installedValues: [String: ProxyValue] {
        [
            "HTTPEnable": .integer(1), "HTTPProxy": .text("127.0.0.1"), "HTTPPort": .integer(port),
            "HTTPSEnable": .integer(1), "HTTPSProxy": .text("127.0.0.1"), "HTTPSPort": .integer(port),
            "SOCKSEnable": .integer(1), "SOCKSProxy": .text("127.0.0.1"), "SOCKSPort": .integer(port),
            "ProxyAutoConfigEnable": .integer(0), "ProxyAutoDiscoveryEnable": .integer(0)
        ]
    }

    func restoration(current: [String: Any], enabled: Bool) throws -> (values: [String: Any], enabled: Bool, changed: Bool) {
        guard previousGuards.count == Self.groups.count else { throw ProxyError.invalidState }
        var result = current
        var preserveProtocolState = false
        var changed = false
        let installed = installedValues

        for (index, keys) in Self.groups.enumerated() {
            let actual = try Self.values(for: keys, in: current)
            let expected = installed.filter { keys.contains($0.key) }
            let original = previousValues.filter { keys.contains($0.key) }
            let sameGuard = Self.fingerprint(keys: Self.guards[index], in: current) == previousGuards[index]
            guard actual == expected, sameGuard else {
                if actual != original || !sameGuard {
                    preserveProtocolState = true
                }
                // An external edit can leave the app's localhost endpoint
                // active. Keep the journal and engine in place in that case.
                if enabled, keys.count == 3, actual != original,
                   actual[keys[0]] == .integer(1),
                   actual[keys[1]] == .text("127.0.0.1"), actual[keys[2]] == .integer(port) {
                    throw ProxyError.proxyChanged
                }
                continue
            }
            for key in keys {
                result[key] = original[key]?.unboxed
            }
            changed = changed || actual != original
        }

        let restoredEnabled = preserveProtocolState || !enabled ? enabled : previousEnabled
        return (result, restoredEnabled, changed || restoredEnabled != enabled)
    }

    private static func values(for keys: [String], in configuration: [String: Any]) throws -> [String: ProxyValue] {
        var values: [String: ProxyValue] = [:]
        for key in keys {
            guard let value = configuration[key] else { continue }
            if let number = value as? NSNumber {
                values[key] = .integer(number.intValue)
            } else if let text = value as? String {
                values[key] = .text(text)
            } else {
                throw ProxyError.invalidState
            }
        }
        return values
    }

    private static func fingerprint(keys: [String], in configuration: [String: Any]) -> Data {
        var hasher = SHA256()
        for key in keys {
            let value = configuration[key] as? String ?? ""
            hasher.update(data: Data("\(value.utf8.count):\(value)".utf8))
        }
        return Data(hasher.finalize())
    }
}

private enum ProxyValue: Codable, Equatable {
    case integer(Int)
    case text(String)

    var unboxed: Any {
        switch self {
        case .integer(let value): return value
        case .text(let value): return value
        }
    }
}

private enum ProxyError: LocalizedError {
    case invalidPort, invalidState, cannotSaveState, pendingRecovery, noUsableService
    case authorization, authenticatedProxy, systemConfiguration, proxyChanged, activeProxy

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "本地代理端口无效。"
        case .invalidState: return "系统代理恢复记录无效。"
        case .cannotSaveState: return "无法保存系统代理恢复记录。"
        case .pendingRecovery: return "请先恢复上次的系统代理设置。"
        case .noUsableService: return "找不到当前网络服务的代理设置。请先连接 Wi-Fi 或以太网。"
        case .authorization: return "未获得修改系统代理的授权。"
        case .authenticatedProxy: return "当前网络已设置带认证的代理，暂无法自动接管。"
        case .systemConfiguration: return "macOS 无法更新系统代理。请确认已授权并重试。"
        case .proxyChanged: return "其他工具修改了当前代理。请先在系统设置中检查代理，再重试恢复。"
        case .activeProxy: return "当前已有其他系统代理正在使用。"
        }
    }
}
