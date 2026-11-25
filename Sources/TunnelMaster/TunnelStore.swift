import AppKit
import Foundation
import SwiftUI
import TunnelMasterCore
import UniformTypeIdentifiers

enum TunnelMode: String {
    case global
    case rules
}

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

@MainActor
final class TunnelStore: ObservableObject {
    @Published var mode: TunnelMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "routingMode") }
    }
    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var profileName: String?
    @Published private(set) var exitIP: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var directDomains: String
    @Published private(set) var proxyDomains: String
    @Published private(set) var useChinaIPRules: Bool
    @Published private(set) var observedFullTunnel = false
    @Published private(set) var checkingExit = false
    @Published private(set) var hasRuleEngine = MihomoSession.executable != nil
    @Published private(set) var needsProxyRecovery = false
    @Published private(set) var changedNetwork = false

    private let storage: URL
    private let systemProxy: SystemProxyController
    private var profile: WireGuardProfile?
    private var session: MihomoSession?
    private var monitor: Timer?

    init() {
        let defaults = UserDefaults.standard
        Self.migratePreferences(defaults)
        mode = TunnelMode(rawValue: defaults.string(forKey: "routingMode") ?? "") ?? .rules
        directDomains = defaults.string(forKey: "directDomains") ?? """
        bilibili.com
        hdslb.com
        taobao.com
        tmall.com
        alicdn.com
        jd.com
        jdcloud.com
        qq.com
        weixin.qq.com
        """
        proxyDomains = defaults.string(forKey: "proxyDomains") ?? ""
        useChinaIPRules = defaults.bool(forKey: "useChinaIPRules")

        storage = Self.storageDirectory()
        systemProxy = SystemProxyController(stateURL: storage.appendingPathComponent("proxy-recovery.json"))

        do {
            try Self.prepareStorage(storage)
            let file = storage.appendingPathComponent("profile.conf")
            if FileManager.default.fileExists(atPath: file.path) {
                profile = try WireGuardProfile.parse(String(contentsOf: file, encoding: .utf8))
                profileName = (try? String(contentsOf: storage.appendingPathComponent("profile-name.txt"), encoding: .utf8))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "本机配置"
            }
        } catch {
            errorMessage = "无法读取本机 WireGuard 配置。请重新导入。"
        }
        refresh()
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func importProfile() {
        guard status == .disconnected else { return }
        let picker = NSOpenPanel()
        picker.title = "导入 WireGuard 配置"
        picker.prompt = "导入"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        if let profileType = UTType(filenameExtension: "conf") {
            picker.allowedContentTypes = [profileType]
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }

        do {
            let file = try String(contentsOf: url, encoding: .utf8)
            let parsed = try WireGuardProfile.parse(file)
            try Self.prepareStorage(storage)
            let name = url.deletingPathExtension().lastPathComponent
            try Self.privateWrite(Data(name.utf8), to: storage.appendingPathComponent("profile-name.txt"))
            try Self.privateWrite(Data(file.utf8), to: storage.appendingPathComponent("profile.conf"))
            profile = parsed
            profileName = name
            errorMessage = nil
        } catch {
            errorMessage = "导入失败。\(error.localizedDescription)"
        }
    }

    func saveRules(direct: String, proxy: String, china: Bool) -> Bool {
        guard status == .disconnected else { return false }
        do {
            let rules = try DomainRules.parse(direct: direct, proxy: proxy, china: china)
            directDomains = rules.direct.joined(separator: "\n")
            proxyDomains = rules.proxy.joined(separator: "\n")
            useChinaIPRules = rules.useChinaIPRules
            let defaults = UserDefaults.standard
            defaults.set(directDomains, forKey: "directDomains")
            defaults.set(proxyDomains, forKey: "proxyDomains")
            defaults.set(useChinaIPRules, forKey: "useChinaIPRules")
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refresh() {
        hasRuleEngine = MihomoSession.executable != nil
        guard status != .connecting, status != .disconnecting else { return }
        if let session, !session.isRunning {
            self.session = nil
            status = .disconnected
            exitIP = nil
            errorMessage = "Mihomo 已停止。请恢复之前的系统代理设置。"
            Task.detached { session.stop() }
        }
        let sessionRunning = session?.isRunning == true
        needsProxyRecovery = !sessionRunning && systemProxy.hasSavedState()
        changedNetwork = sessionRunning && !systemProxy.appliesToPrimaryService()
        Task {
            let anotherVPN = await Task.detached { MacCommand.hasActiveVPN() }.value
            observedFullTunnel = anotherVPN
        }
    }

    func toggle() {
        switch status {
        case .connected: disconnect()
        case .disconnected:
            if systemProxy.hasSavedState() { disconnect() }
            else { connect() }
        case .connecting, .disconnecting: break
        }
    }

    func checkExit() {
        guard status == .connected, !checkingExit, let session else { return }
        checkingExit = true
        Task {
            do {
                let ip = try await Task.detached { try session.checkExit() }.value
                if self.session === session { exitIP = ip }
            } catch {
                if self.session === session {
                    exitIP = nil
                    errorMessage = error.localizedDescription
                }
            }
            checkingExit = false
        }
    }

    func quit() {
        guard status != .connecting, status != .disconnecting else { return }
        if session != nil || systemProxy.hasSavedState() {
            disconnect(quitAfterward: true)
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func connect() {
        guard let profile, let executable = MihomoSession.executable else {
            errorMessage = "连接需要本机 WireGuard 配置和 Mihomo。"
            return
        }
        let rules: DomainRules
        do {
            rules = mode == .rules
                ? try DomainRules.parse(direct: directDomains, proxy: proxyDomains, china: useChinaIPRules)
                : DomainRules(direct: [], proxy: [], useChinaIPRules: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = .connecting
        errorMessage = nil
        exitIP = nil
        let storage = self.storage
        let systemProxy = self.systemProxy
        Task {
            var pendingSession: MihomoSession?
            do {
                let hasAnotherVPN = await Task.detached { MacCommand.hasActiveVPN() }.value
                observedFullTunnel = hasAnotherVPN
                guard !hasAnotherVPN else {
                    status = .disconnected
                    errorMessage = "请先断开当前 macOS VPN，再连接 TunnelMaster。"
                    return
                }

                let geoIP = rules.useChinaIPRules ? try await Self.ensureGeoIP(at: storage) : nil
                let next = try await Task.detached {
                    try MihomoSession.start(
                        executable: executable, workDirectory: storage, profile: profile, rules: rules, geoIP: geoIP
                    )
                }.value
                pendingSession = next
                try await Task.detached { try systemProxy.enable(port: next.port) }.value
                session = next
                status = .connected
                checkExit()
            } catch {
                if let pendingSession {
                    if systemProxy.hasSavedState() && pendingSession.isRunning {
                        session = pendingSession
                        status = .connected
                        errorMessage = "系统代理未完整应用。请先断开以恢复设置。\(error.localizedDescription)"
                        return
                    }
                    await Task.detached { pendingSession.stop() }.value
                }
                status = .disconnected
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private func disconnect(quitAfterward: Bool = false) {
        status = .disconnecting
        let runningSession = session
        let systemProxy = self.systemProxy
        Task {
            do {
                try await Task.detached { try systemProxy.disable() }.value
                session = nil
                if let runningSession {
                    await Task.detached { runningSession.stop() }.value
                }
                status = .disconnected
                exitIP = nil
                errorMessage = nil
                refresh()
                if quitAfterward { NSApplication.shared.terminate(nil) }
            } catch {
                status = runningSession?.isRunning == true ? .connected : .disconnected
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private static func migratePreferences(_ defaults: UserDefaults) {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let previous = defaults.persistentDomain(forName: "com.x1angyulu.TunnelMenu") else { return }
        let current = defaults.persistentDomain(forName: bundleID) ?? [:]
        for key in ["routingMode", "directDomains", "proxyDomains", "useChinaIPRules"] where current[key] == nil {
            if let value = previous[key] { defaults.set(value, forKey: key) }
        }
    }

    private static func storageDirectory() -> URL {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = support.appendingPathComponent("TunnelMaster", isDirectory: true)
        let previous = support.appendingPathComponent("TunnelMenu", isDirectory: true)
        guard !files.fileExists(atPath: current.path), files.fileExists(atPath: previous.path) else { return current }
        do {
            // Move the config and proxy recovery state together, without duplicating the private key.
            try files.moveItem(at: previous, to: current)
            return current
        } catch {
            return files.fileExists(atPath: previous.path) ? previous : current
        }
    }

    private static func prepareStorage(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func ensureGeoIP(at storage: URL) async throws -> URL {
        let cached = storage.appendingPathComponent("Country.mmdb")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let source = URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb")!
        var request = URLRequest(url: source)
        request.timeoutInterval = 18
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1024..<35_000_000).contains(size) else { throw SessionError.geoIPUnavailable }
            let data = try Data(contentsOf: temporary)
            // MaxMind files end with a header marker followed by the metadata map.
            let marker = Data([0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8))
            guard data.suffix(131_072).range(of: marker) != nil else { throw SessionError.geoIPUnavailable }
            try privateWrite(data, to: cached)
            return cached
        } catch {
            throw SessionError.geoIPUnavailable
        }
    }
}
