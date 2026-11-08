// The main window: a sidebar (Settings / Models) with a detail pane.

import SwiftUI
import Observation
import PrivoVoiceKit

/// Sidebar destinations.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, settings, models
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .settings: return "Settings"
        case .models: return "Models"
        }
    }
    var systemImage: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
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
            List(selection: $route.selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            // The system Liquid Glass sidebar draws its own floating surface and
            // selection (tinted by the app accent via `.tint` on the scene).
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                StatusFooter()
            }
        } detail: {
            Group {
                switch route.selection {
                case .dashboard: DashboardPane()
                case .settings: SettingsPane()
                case .models: ModelsPane()
                }
            }
            .detailPanelStyle()                        // panelTint wash
            // With the sidebar's 190 this sets the window's minimum width.
            .navigationSplitViewColumnWidth(min: 510, ideal: 650)
        }
        // Transparent, title-less toolbar so content fills to the top edge.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        // Warm tint over the window's frosted (behind-window) material, which
        // samples the desktop.
        .background(TintWash(tint: AppTheme.backgroundTint).ignoresSafeArea())
        .containerBackground(.regularMaterial, for: .window)
        .onAppear { env.store.refresh() }   // rescan the models folder on open
        // First-run onboarding, full-bleed over the main UI until completed/skipped.
        .overlay {
            if !env.settings.hasCompletedOnboarding {
                OnboardingView {
                    withAnimation(.smooth) { env.settings.hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
    }
}

/// A compact footer under the sidebar: live status + the model currently in use.
private struct StatusFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(env.appState.phase.statusColor).frame(width: 8, height: 8)
                Text(env.appState.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: inUseModel == nil ? "cpu" : "checkmark.seal.fill")
                    .imageScale(.small)
                    .foregroundStyle(inUseModel == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.accent))
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
}
