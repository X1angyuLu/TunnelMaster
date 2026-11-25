import Combine
import Darwin
import Foundation
import Security
import TunnelMasterCore

enum DigitalOceanCredentialStorage: String, CaseIterable, Identifiable {
    case keychain, localFile

    var id: Self { self }

    var title: String {
        switch self {
        case .keychain: "macOS 钥匙串"
        case .localFile: "本机文件"
        }
    }
}

@MainActor
final class DigitalOceanSource: ObservableObject {
    struct Snapshot: Sendable {
        let report: DigitalOceanBandwidthReport
        let fetchedAt: Date
    }

    @Published private(set) var dropletID: String?
    @Published private(set) var credentialStorage: DigitalOceanCredentialStorage
    @Published private(set) var report: DigitalOceanBandwidthReport?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var monthlyTransfer: DigitalOceanMonthlyTransfer?
    @Published private(set) var isLoadingMonthlyTransfer = false
    @Published private(set) var monthlyTransferError: String?

    private let defaults = UserDefaults.standard
    private let client = DigitalOceanBandwidthClient()
    private let preference = "digitalOceanConfiguration"
    private let legacyPreference = "digitalOceanDropletID"
    private let localCredentialFile: MonitoringLocalFile
    private var requestID: UUID?
    private var reportDays: Int?
    private var snapshots: [Int: Snapshot] = [:]
    private var pending: [Int: Task<Snapshot, Error>] = [:]
    private var credentialRevision = UUID()
    private var pendingMonthlyTransfer: Task<DigitalOceanMonthlyTransfer, Error>?
    private var monthlyTransferFetchedAt: Date?

    init(storage: URL) {
        localCredentialFile = MonitoringLocalFile(directory: storage)
        let configuration = defaults.dictionary(forKey: preference)
        credentialStorage = (configuration?["storage"] as? String)
            .flatMap(DigitalOceanCredentialStorage.init(rawValue:)) ?? .keychain
        dropletID = configuration?["dropletID"] as? String ?? defaults.string(forKey: legacyPreference)
    }

    func credentials(dropletID: String, token: String, storage: DigitalOceanCredentialStorage) async throws {
        let credential = MonitoringCredential(
            dropletID: dropletID.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let request = beginRequest()
        defer { finishRequest(request) }
        let initial = try await fetch(credential, days: 1)
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
        switch storage {
        case .keychain:
            try MonitoringKeychain.store(credential)
            if credentialStorage == .localFile { try localCredentialFile.remove() }
        case .localFile:
            try localCredentialFile.store(credential)
        }
        clearSnapshots()
        saveConfiguration(dropletID: credential.dropletID, storage: storage)
        let snapshot = Snapshot(report: initial, fetchedAt: .now)
        snapshots[1] = snapshot
        updateReport(snapshot, days: 1)
    }

    func saveCredentialLocally() throws {
        guard credentialStorage == .keychain, let dropletID else { return }
        let credential = try MonitoringKeychain.load()
        guard credential.dropletID == dropletID else { throw DigitalOceanBandwidthError.invalidDropletID }
        try localCredentialFile.store(credential)
        saveConfiguration(dropletID: dropletID, storage: .localFile)
        errorMessage = nil
    }

    func load(days: Int) async {
        guard dropletID != nil else { return }
        let request = beginRequest()
        if reportDays != days {
            report = nil
            lastUpdated = nil
        }
        defer { finishRequest(request) }
        do {
            let result = try await bandwidth(days: days, maxAge: 0)
            try Task.checkCancellation()
            guard requestID == request else { return }
            updateReport(result, days: days)
        } catch is CancellationError {
            return
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func removeCredentials() throws {
        switch credentialStorage {
        case .keychain: try MonitoringKeychain.remove()
        case .localFile: try localCredentialFile.remove()
        }
        clearSnapshots()
        requestID = nil
        isLoading = false
        errorMessage = nil
        dropletID = nil
        report = nil
        lastUpdated = nil
        reportDays = nil
        defaults.removeObject(forKey: legacyPreference)
        defaults.removeObject(forKey: preference)
        credentialStorage = .keychain
    }

    func bandwidth(days: Int, maxAge: TimeInterval) async throws -> Snapshot {
        guard let dropletID else { throw DigitalOceanBandwidthError.invalidDropletID }
        try Task.checkCancellation()
        if let snapshot = snapshots[days], maxAge > 0,
           abs(snapshot.fetchedAt.timeIntervalSinceNow) < maxAge {
            return snapshot
        }
        let revision = credentialRevision
        if let request = pending[days] {
            let snapshot = try await request.value
            guard credentialRevision == revision else { throw CancellationError() }
            return snapshot
        }

        let credential = try storedCredential(dropletID: dropletID)
        let request = Task { Snapshot(report: try await fetch(credential, days: days), fetchedAt: .now) }
        pending[days] = request
        defer {
            if credentialRevision == revision { pending[days] = nil }
        }
        let snapshot = try await request.value
        guard credentialRevision == revision else { throw CancellationError() }
        snapshots[days] = snapshot
        return snapshot
    }

    func loadMonthlyTransfer(force: Bool = false) async {
        guard let dropletID, !Task.isCancelled, pendingMonthlyTransfer == nil else { return }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        if let monthlyTransfer, !calendar.isDate(now, equalTo: monthlyTransfer.monthStart, toGranularity: .month) {
            self.monthlyTransfer = nil
            monthlyTransferFetchedAt = nil
        }
        if !force, let fetchedAt = monthlyTransferFetchedAt, now.timeIntervalSince(fetchedAt) < 300 { return }

        monthlyTransferError = nil
        isLoadingMonthlyTransfer = true
        let revision = credentialRevision
        defer {
            if credentialRevision == revision {
                pendingMonthlyTransfer = nil
                isLoadingMonthlyTransfer = false
            }
        }
        do {
            let credential = try storedCredential(dropletID: dropletID)
            let request = Task { [client] in
                try await client.monthlyTransfer(dropletID: credential.dropletID, token: credential.token, now: now)
            }
            pendingMonthlyTransfer = request
            let result = try await request.value
            guard credentialRevision == revision else { return }
            monthlyTransfer = result
            monthlyTransferFetchedAt = .now
        } catch is CancellationError {
            return
        } catch {
            guard credentialRevision == revision else { return }
            monthlyTransferError = error.localizedDescription
        }
    }

    private func storedCredential(dropletID: String) throws -> MonitoringCredential {
        let credential = switch credentialStorage {
        case .keychain: try MonitoringKeychain.load()
        case .localFile: try localCredentialFile.load()
        }
        guard credential.dropletID == dropletID else { throw DigitalOceanBandwidthError.invalidDropletID }
        return credential
    }

    private func clearSnapshots() {
        credentialRevision = UUID()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        snapshots.removeAll()
        pendingMonthlyTransfer?.cancel()
        pendingMonthlyTransfer = nil
        monthlyTransferFetchedAt = nil
        monthlyTransfer = nil
        monthlyTransferError = nil
        isLoadingMonthlyTransfer = false
    }

    private func saveConfiguration(dropletID: String, storage: DigitalOceanCredentialStorage) {
        defaults.set(["dropletID": dropletID, "storage": storage.rawValue], forKey: preference)
        self.dropletID = dropletID
        credentialStorage = storage
    }

    private func beginRequest() -> UUID {
        let request = UUID()
        requestID = request
        isLoading = true
        errorMessage = nil
        return request
    }

    private func finishRequest(_ request: UUID) {
        guard requestID == request else { return }
        requestID = nil
        isLoading = false
    }

    private func fetch(_ credential: MonitoringCredential, days: Int) async throws -> DigitalOceanBandwidthReport {
        let now = Date()
        return try await client.report(
            dropletID: credential.dropletID, token: credential.token,
            from: now.addingTimeInterval(-Double(days) * 86_400), until: now
        )
    }

    private func updateReport(_ snapshot: Snapshot, days: Int) {
        report = snapshot.report
        reportDays = days
        lastUpdated = snapshot.fetchedAt
    }
}

private struct MonitoringCredential: Codable {
    let dropletID: String
    let token: String
}

private struct MonitoringLocalFile {
    let directory: URL

    private var url: URL { directory.appendingPathComponent("digitalocean-credentials.json") }

    func store(_ credential: MonitoringCredential) throws {
        do {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let attributes = try files.attributesOfItem(atPath: directory.path)
            guard hasPrivateAccess(attributes), attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw LocalFileError.unavailable
            }
            let staged = directory.appendingPathComponent(".digitalocean-\(UUID().uuidString)")
            defer { try? files.removeItem(at: staged) }
            let data = try JSONEncoder().encode(credential)
            try TunnelStore.privateWrite(data, to: staged)
            guard rename(staged.path, url.path) == 0 else { throw LocalFileError.unavailable }
        } catch {
            throw LocalFileError.unavailable
        }
    }

    func load() throws -> MonitoringCredential {
        do {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw LocalFileError.unavailable }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  (1...16_384).contains(info.st_size), let data = try input.read(upToCount: 16_385),
                  data.count <= 16_384 else { throw LocalFileError.unavailable }
            return try JSONDecoder().decode(MonitoringCredential.self, from: data)
        } catch {
            throw LocalFileError.unavailable
        }
    }

    func remove() throws {
        // unlink removes only a file entry, so an unexpected directory is never deleted.
        guard unlink(url.path) == 0 || errno == ENOENT else { throw LocalFileError.unavailable }
    }

    private func hasPrivateAccess(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let mode = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid() && mode.intValue & 0o077 == 0
    }

    private enum LocalFileError: LocalizedError {
        case unavailable

        var errorDescription: String? { "无法访问本机 DigitalOcean 令牌文件。请在设置中重新保存令牌。" }
    }
}

private enum MonitoringKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.x1angyulu.TunnelMaster.digitalocean.monitoring",
            kSecAttrAccount as String: "DigitalOcean Monitoring",
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func store(_ credential: MonitoringCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let changes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            let item = query.merging(changes, uniquingKeysWith: { _, new in new })
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(updated)
        }
    }

    static func load() throws -> MonitoringCredential {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(lookup as CFDictionary, &result))
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(MonitoringCredential.self, from: data) else {
            throw KeychainError.missing
        }
        return credential
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        if status == errSecItemNotFound { throw KeychainError.missing }
        guard status == errSecSuccess else { throw KeychainError.unavailable }
    }

    private enum KeychainError: LocalizedError {
        case missing
        case unavailable

        var errorDescription: String? {
            switch self {
            case .missing: "本机钥匙串里没有 DigitalOcean 令牌。请重新连接。"
            case .unavailable: "无法访问 macOS 钥匙串。请确认已解锁并允许 TunnelMaster 访问。"
            }
        }
    }
}
