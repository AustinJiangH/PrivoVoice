// The main window: a sidebar (Settings / Models) with a detail pane.

import SwiftUI
import Observation
import PrivoVoiceKit

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
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                StatusFooter()
            }
        } detail: {
            switch route.selection {
            case .settings: SettingsPane()
            case .models: ModelsPane()
            }
        }
        .onAppear { env.store.refresh() }   // rescan the models folder on open
    }
}

/// A compact footer under the sidebar: live status + the model currently in use.
private struct StatusFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(env.appState.phase.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: inUseModel == nil ? "cpu" : "checkmark.seal.fill")
                    .imageScale(.small)
                    .foregroundStyle(inUseModel == nil ? .secondary : Color.accentColor)
                Text(inUseModel?.displayName ?? "No model selected")
                    .font(.caption.weight(inUseModel == nil ? .regular : .semibold))
                    .foregroundStyle(inUseModel == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var inUseModel: ModelSpec? {
        env.settings.selectedModelID.flatMap(ModelCatalog.spec(id:))
    }

    private var statusColor: Color {
        switch env.appState.phase {
        case .idle: return .secondary
        case .listening: return .green
        case .transcribing: return .orange
        }
    }
}
