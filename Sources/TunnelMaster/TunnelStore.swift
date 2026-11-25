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

struct TrafficSnapshot {
    let downloadRate: Double?
    let uploadRate: Double?
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connectionCount: Int
}

struct TrafficSample: Identifiable {
    let timestamp: Date
    let downloadRate: Double
    let uploadRate: Double

    var id: Date { timestamp }
}

@MainActor
final class TunnelStore: ObservableObject {
    @Published private(set) var mode: TunnelMode {
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
    @Published private(set) var changingMode = false
    @Published private(set) var connectedAt: Date?
    @Published private(set) var traffic: TrafficSnapshot?
    @Published private(set) var trafficHistory: [TrafficSample] = []
    @Published private(set) var historyRevision = 0
    @Published private(set) var historySaveIssue = false
    let digitalOcean = DigitalOceanSource()

    private let storage: URL
    private let systemProxy: SystemProxyController
    private let historyStore: TrafficHistoryStore
    private var profile: WireGuardProfile?
    private var session: MihomoSession?
    private var monitor: Timer?
    private var metricsTask: Task<Void, Never>?
    private var metricsVisible = false
    private var lastReading: (metrics: MihomoMetrics, instant: ContinuousClock.Instant)?
    private var historyRecorder: TrafficHistoryRecorder?
    private var lastHistoryObservation: SuspendingClock.Instant?
    private var historyPending: [Date: TrafficHistoryEntry] = [:]
    private var historyWrite: Task<Void, Never>?
    private var lastHistoryWrite: ContinuousClock.Instant?

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
        historyStore = TrafficHistoryStore(url: storage.appendingPathComponent("traffic-history.sqlite3"))

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
        acceptHandoff()
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
            clearMetrics()
            status = .disconnected
            exitIP = nil
            errorMessage = "Mihomo 已停止。请恢复之前的系统代理设置。"
            Task.detached { session.stop() }
            Task { await flushHistory() }
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
        guard !changingMode else { return }
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
        guard status != .connecting, status != .disconnecting, !changingMode else { return }
        if session != nil || systemProxy.hasSavedState() {
            disconnect(quitAfterward: true)
        } else {
            Task {
                await flushHistory()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func trafficEntries(from: Date, until: Date) async throws -> [TrafficHistoryEntry] {
        try await historyStore.entries(from: from, until: until)
    }

    func selectMode(_ next: TunnelMode) {
        guard next != mode, !changingMode else { return }
        if status == .disconnected {
            mode = next
            refresh()
            return
        }
        guard status == .connected, let session, let profile else { return }
        let rules: DomainRules
        do {
            rules = try routingRules(for: next)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        changingMode = true
        errorMessage = nil
        Task {
            defer { changingMode = false }
            do {
                let geoIP = rules.useChinaIPRules ? try await Self.ensureGeoIP(at: storage) : nil
                guard self.session === session, session.isRunning else { return }
                try await Task.detached { try session.applyRules(profile: profile, rules: rules, geoIP: geoIP) }.value
                guard self.session === session, session.isRunning else { return }
                mode = next
            } catch {
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private func routingRules(for mode: TunnelMode) throws -> DomainRules {
        switch mode {
        case .rules: try DomainRules.parse(direct: directDomains, proxy: proxyDomains, china: useChinaIPRules)
        case .global: DomainRules(direct: [], proxy: [], useChinaIPRules: false)
        }
    }

    func setMetricsVisible(_ visible: Bool) {
        metricsVisible = visible
    }

    private func activateSession(_ session: MihomoSession, continuingSince: Date? = nil, baseline: MihomoMetrics? = nil) {
        self.session = session
        let start = Date()
        connectedAt = continuingSince ?? start
        status = .connected
        historyRecorder = TrafficHistoryRecorder(downloaded: baseline?.downloadTotal ?? 0, uploaded: baseline?.uploadTotal ?? 0)
        lastHistoryObservation = .now
        if continuingSince == nil {
            queueHistory([TrafficHistoryEntry(
                timestamp: TrafficHistoryRecorder.bucketStart(for: start), downloaded: 0, uploaded: 0,
                connectedSeconds: 0, peakDownloadRate: 0, peakUploadRate: 0, sessionsStarted: 1
            )])
        }
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                let reading = await Task.detached(priority: .utility) { try? session.readMetrics() }.value
                guard !Task.isCancelled, self?.session === session, session.isRunning else { return }
                self?.updateMetrics(reading)
                do {
                    try await Task.sleep(for: .seconds(self?.metricsVisible == true ? 2 : 5))
                } catch {
                    return
                }
            }
        }
    }

    private func updateMetrics(_ reading: MihomoMetrics?) {
        let now = Date()
        var history = trafficHistory.filter { now.timeIntervalSince($0.timestamp) <= 60 }
        guard let reading else {
            lastReading = nil
            traffic = nil
            trafficHistory = history
            recordHistory(at: now, reading: nil, downloadRate: nil, uploadRate: nil)
            return
        }

        let instant = ContinuousClock.now
        var downloadRate: Double?
        var uploadRate: Double?
        if let previous = lastReading {
            let elapsed = previous.instant.duration(to: instant).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if reading.downloadTotal < previous.metrics.downloadTotal || reading.uploadTotal < previous.metrics.uploadTotal {
                history.removeAll()
            } else if seconds > 0 {
                let down = Double(reading.downloadTotal - previous.metrics.downloadTotal) / seconds
                let up = Double(reading.uploadTotal - previous.metrics.uploadTotal) / seconds
                downloadRate = down
                uploadRate = up
                history.append(TrafficSample(timestamp: now, downloadRate: down, uploadRate: up))
            }
        }
        lastReading = (reading, instant)
        trafficHistory = history
        traffic = TrafficSnapshot(
            downloadRate: downloadRate, uploadRate: uploadRate,
            downloadTotal: reading.downloadTotal, uploadTotal: reading.uploadTotal, connectionCount: reading.connectionCount
        )
        recordHistory(at: now, reading: reading, downloadRate: downloadRate, uploadRate: uploadRate)
    }

    private func clearMetrics() {
        metricsTask?.cancel()
        metricsTask = nil
        lastReading = nil
        lastHistoryObservation = nil
        historyRecorder = nil
        connectedAt = nil
        traffic = nil
        trafficHistory = []
    }

    private func recordHistory(at date: Date, reading: MihomoMetrics?, downloadRate: Double?, uploadRate: Double?) {
        guard var recorder = historyRecorder, let previous = lastHistoryObservation else { return }
        let instant = SuspendingClock.now
        let elapsed = previous.duration(to: instant).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        lastHistoryObservation = instant
        queueHistory(recorder.record(
            at: date, connectedSeconds: min(seconds, 12),
            totals: reading.map { ($0.downloadTotal, $0.uploadTotal) },
            downloadRate: downloadRate, uploadRate: uploadRate, connections: reading?.connectionCount ?? 0
        ))
        historyRecorder = recorder
    }

    private func queueHistory(_ entries: [TrafficHistoryEntry]) {
        mergePendingHistory(entries)
        if lastHistoryWrite.map({ $0.duration(to: .now) >= .seconds(15) }) ?? true {
            startHistoryWrite()
        }
    }

    private func mergePendingHistory(_ entries: [TrafficHistoryEntry]) {
        for entry in entries {
            let timestamp = entry.timestamp
            guard let existing = historyPending[timestamp] else {
                historyPending[timestamp] = entry
                continue
            }
            historyPending[timestamp] = TrafficHistoryEntry(
                timestamp: timestamp, downloaded: existing.downloaded + entry.downloaded,
                uploaded: existing.uploaded + entry.uploaded,
                connectedSeconds: existing.connectedSeconds + entry.connectedSeconds,
                peakDownloadRate: max(existing.peakDownloadRate, entry.peakDownloadRate),
                peakUploadRate: max(existing.peakUploadRate, entry.peakUploadRate),
                sessionsStarted: existing.sessionsStarted + entry.sessionsStarted,
                peakConnections: max(existing.peakConnections, entry.peakConnections), samples: existing.samples + entry.samples
            )
        }
    }

    private func startHistoryWrite() {
        guard historyWrite == nil, !historyPending.isEmpty else { return }
        let entries = Array(historyPending.values)
        historyPending.removeAll(keepingCapacity: true)
        lastHistoryWrite = .now
        historyWrite = Task { [weak self, historyStore] in
            defer { self?.historyWrite = nil }
            do {
                try await historyStore.append(entries)
                self?.historySaveIssue = false
                self?.historyRevision += 1
            } catch {
                self?.mergePendingHistory(entries)
                self?.historySaveIssue = true
            }
        }
    }

    private func flushHistory() async {
        await historyWrite?.value
        startHistoryWrite()
        await historyWrite?.value
    }

    private func acceptHandoff() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--handoff"), arguments.indices.contains(index + 1) else { return }
        let file = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let receipt = file.appendingPathExtension("ready")
        let storageFolder = storage.resolvingSymlinksInPath()
        let systemProxy = self.systemProxy
        status = .connecting
        Task {
            do {
                let (session, metrics, handoff) = try await Task.detached {
                    guard file.deletingLastPathComponent().resolvingSymlinksInPath() == storageFolder,
                          file.lastPathComponent.hasPrefix("handoff-"), file.pathExtension == "json",
                          let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                          attributes[.type] as? FileAttributeType == .typeRegular,
                          attributes[.ownerAccountID] as? UInt32 == getuid(),
                          attributes[.posixPermissions] as? Int == 0o600 else { throw HandoffError.invalid }
                    let handoff = try JSONDecoder().decode(SessionHandoff.self, from: Data(contentsOf: file))
                    guard abs(handoff.createdAt - Date().timeIntervalSince1970) <= 300,
                          systemProxy.ownsActiveProxy(port: handoff.port) else { throw HandoffError.invalid }
                    let session = try MihomoSession.adopt(
                        pid: handoff.processID,
                        workingDirectory: URL(fileURLWithPath: handoff.workingDirectory, isDirectory: true),
                        port: handoff.port,
                        metricsSocket: URL(fileURLWithPath: handoff.metricsSocket)
                    )
                    return (session, try session.readMetrics(), handoff)
                }.value
                let acknowledgement = "\(ProcessInfo.processInfo.processIdentifier) \(session.processID)\n"
                try Self.privateWrite(Data(acknowledgement.utf8), to: receipt)
                activateSession(session, continuingSince: Date(timeIntervalSince1970: min(handoff.connectedAt, Date().timeIntervalSince1970)), baseline: metrics)
                checkExit()
            } catch {
                status = .disconnected
                errorMessage = "无法接管当前连接。"
                refresh()
            }
        }
    }

    private func connect() {
        guard let profile, let executable = MihomoSession.executable else {
            errorMessage = "连接需要本机 WireGuard 配置和 Mihomo。"
            return
        }
        let rules: DomainRules
        do {
            rules = try routingRules(for: mode)
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
                activateSession(next)
                checkExit()
            } catch {
                if let pendingSession {
                    if systemProxy.hasSavedState() && pendingSession.isRunning {
                        activateSession(pendingSession)
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
                metricsTask?.cancel()
                if let runningSession {
                    let reading = await Task.detached(priority: .utility) { try? runningSession.readMetrics() }.value
                    updateMetrics(reading)
                    await Task.detached { runningSession.stop() }.value
                }
                session = nil
                clearMetrics()
                await flushHistory()
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

private struct SessionHandoff: Decodable, Sendable {
    let processID: Int32
    let port: Int
    let workingDirectory: String
    let metricsSocket: String
    let createdAt: TimeInterval
    let connectedAt: TimeInterval
}

private enum HandoffError: Error {
    case invalid
}
