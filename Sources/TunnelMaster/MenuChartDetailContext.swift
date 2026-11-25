import Combine
import Foundation
import SwiftUI

enum MenuChartDetailSource: Hashable {
    case live, local, server
}

struct MenuChartDetailContext: Hashable {
    let source: MenuChartDetailSource
    let range: MenuTrafficRange
}

@MainActor
final class MenuChartDetailSelection: ObservableObject {
    @Published var selectedDate: Date?
}

private struct ChartDetailControllerKey: EnvironmentKey {
    static let defaultValue: MenuChartDetailController? = nil
}

private struct ChartDetailContextKey: EnvironmentKey {
    static let defaultValue: MenuChartDetailContext? = nil
}

extension EnvironmentValues {
    var menuChartDetailController: MenuChartDetailController? {
        get { self[ChartDetailControllerKey.self] }
        set { self[ChartDetailControllerKey.self] = newValue }
    }

    var menuChartDetailContext: MenuChartDetailContext? {
        get { self[ChartDetailContextKey.self] }
        set { self[ChartDetailContextKey.self] = newValue }
    }
}
