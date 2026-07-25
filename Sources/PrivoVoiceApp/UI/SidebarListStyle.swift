// Sidebar list chrome ported from Voxtine: a wood selection wash instead of the
// system blue pill, and a transparent scroll background so the tinted sidebar
// material shows through.

import AppKit
import SwiftUI

extension AppTheme {
    /// Selected sidebar row wash — accent tint, not system accent blue.
    static func sidebarSelectionBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accent.opacity(0.38) : accent.opacity(0.22)
    }

    /// Horizontal inset for the selection pill inside a sidebar row.
    static let sidebarSelectionHorizontalInset: CGFloat = 8
}

/// Disables the default macOS blue `NSTableView` selection pill so
/// `listRowBackground` is the only highlight. Attached per-row so each `List`
/// configures its own table (not the first table in the window).
struct SidebarListSelectionDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarListConfiguratorView {
        SidebarListConfiguratorView()
    }

    func updateNSView(_ view: SidebarListConfiguratorView, context: Context) {
        view.configureAncestorTableView()
    }
}

final class SidebarListConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureAncestorTableView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.configureAncestorTableView()
        }
    }

    fileprivate func configureAncestorTableView() {
        guard let table = findTableView(startingAt: self) else { return }
        table.selectionHighlightStyle = .none
    }

    /// Walk up from this row/cell view only — never scan the whole window.
    private func findTableView(startingAt view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView,
               let table = scroll.documentView as? NSTableView {
                return table
            }
            if let table = node as? NSTableView {
                return table
            }
            current = node.superview
        }
        return nil
    }
}

extension View {
    /// Wood selection wash behind the row; text stays the system default.
    func sidebarListRowBackground(isSelected: Bool) -> some View {
        modifier(SidebarListRowBackground(isSelected: isSelected))
    }

    /// Transparent list scroll background so the tinted sidebar material shows.
    func sidebarListChrome() -> some View {
        scrollContentBackground(.hidden)
    }
}

private struct SidebarListRowBackground: ViewModifier {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                SidebarListSelectionDisabler()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .listRowBackground(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.sidebarSelectionBackground(for: colorScheme))
                            .padding(.horizontal, AppTheme.sidebarSelectionHorizontalInset)
                    } else {
                        Color.clear
                    }
                }
            )
    }
}
