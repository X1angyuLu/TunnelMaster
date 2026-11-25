import Combine
import Foundation
import Security
import TunnelMasterCore

@MainActor
final class DigitalOceanSource: ObservableObject {
    struct Snapshot: Sendable {
        let report: DigitalOceanBandwidthReport
        let fetchedAt: Date
    }

    @Published private(set) var dropletID: String?
    @Published private(set) var report: DigitalOceanBandwidthReport?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let client = DigitalOceanBandwidthClient()
    private let preference = "digitalOceanDropletID"
    private var requestID: UUID?
    private var reportDays: Int?
    private var snapshots: [Int: Snapshot] = [:]
    private var pending: [Int: Task<Snapshot, Error>] = [:]
    private var credentialRevision = UUID()

    init() {
        dropletID = defaults.string(forKey: preference)
    }

    func credentials(dropletID: String, token: String) async throws {
        let credential = MonitoringCredential(
            dropletID: dropletID.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let request = beginRequest()
        defer { finishRequest(request) }
        let initial = try await fetch(credential, days: 1)
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
        try MonitoringKeychain.store(credential)
        clearSnapshots()
        self.dropletID = credential.dropletID
        defaults.set(credential.dropletID, forKey: preference)
        let snapshot = Snapshot(report: initial, fetchedAt: .now)
        snapshots[1] = snapshot
        updateReport(snapshot, days: 1)
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
        try MonitoringKeychain.remove()
        clearSnapshots()
        requestID = nil
        isLoading = false
        errorMessage = nil
        dropletID = nil
        report = nil
        lastUpdated = nil
        reportDays = nil
        defaults.removeObject(forKey: preference)
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

        let credential = try MonitoringKeychain.load()
        guard credential.dropletID == dropletID else { throw DigitalOceanBandwidthError.invalidDropletID }
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

    private func clearSnapshots() {
        credentialRevision = UUID()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        snapshots.removeAll()
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
