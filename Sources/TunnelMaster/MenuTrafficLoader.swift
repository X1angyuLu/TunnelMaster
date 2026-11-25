import Combine
import Foundation

@MainActor
final class MenuTrafficLoader: ObservableObject {
    @Published private(set) var report: MenuTrafficReport?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private enum Selection: Equatable {
        case local(MenuTrafficRange)
        case server(MenuTrafficRange, String, Int)
    }

    private var selection: Selection?
    private var request: UUID?

    func report(for range: MenuTrafficRange, serverID: String?, monitoringRevision: Int?) -> MenuTrafficReport? {
        let expected = if let serverID, let monitoringRevision {
            Selection.server(range, serverID, monitoringRevision)
        } else {
            Selection.local(range)
        }
        return selection == expected ? report : nil
    }

    func loadLocal(store: TunnelStore, range: MenuTrafficRange) async {
        let now = Date()
        let calendar = Calendar.current
        let interval = range.localInterval(now: now, calendar: calendar)
        await load(.local(range)) {
            let entries = try await store.trafficEntries(from: interval.start, until: interval.end)
            return .local(range: range, entries: entries, now: now, calendar: calendar)
        }
    }

    func loadServer(source: DigitalOceanSource, range: MenuTrafficRange, force: Bool = false) async {
        guard let dropletID = source.dropletID else { return }
        let monitoringRevision = source.monitoringRevision
        await load(.server(range, dropletID, monitoringRevision)) {
            guard source.monitoringRevision == monitoringRevision else { throw CancellationError() }
            let snapshot = try await source.bandwidth(days: range.days, maxAge: force ? 0 : 120)
            return .digitalOcean(range: range, report: snapshot.report, updatedAt: snapshot.fetchedAt)
        }
    }

    private func load(_ selection: Selection, operation: () async throws -> MenuTrafficReport) async {
        guard !Task.isCancelled else { return }
        if self.selection != selection {
            self.selection = selection
            report = nil
        }
        let id = UUID()
        request = id
        isLoading = true
        errorMessage = nil
        defer {
            if request == id {
                isLoading = false
                request = nil
            }
        }
        do {
            let result = try await operation()
            if request == id, !Task.isCancelled { report = result }
        } catch is CancellationError {
            return
        } catch {
            if request == id, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
