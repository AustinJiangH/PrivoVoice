// The main window: a sidebar (Settings / Models) with a detail pane.

import SwiftUI
import Observation
import VoixfulKit

/// Sidebar destinations.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case settings, models
    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .models: return "Models"
        }
    }
    var systemImage: String {
        switch self {
        case .settings: return "gearshape"
        case .models: return "square.stack.3d.up"
        }
    }
}

/// Sidebar selection, shared so the menu bar can jump straight to a pane.
@MainActor
@Observable
final class Router {
    var selection: SidebarItem = .models
    func select(_ item: SidebarItem) { selection = item }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var route = env.route
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $route.selection) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                StatusFooter(appState: env.appState)
            }
        } detail: {
            switch route.selection {
            case .settings: SettingsPane()
            case .models: ModelsPane()
            }
        }
    }
}

/// A compact live-status footer under the sidebar.
private struct StatusFooter: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(appState.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch appState.phase {
        case .idle: return .secondary
        case .listening: return .green
        case .transcribing: return .orange
        }
    }
}
