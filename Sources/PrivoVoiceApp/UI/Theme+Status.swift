// The single source of truth mapping app domain state → theme colors, so every
// surface (HUD, sidebar footer, menu bar) renders identical status colors. Lives
// in the app target because it maps PrivoVoiceKit types to SwiftUI Colors.

import SwiftUI
import PrivoVoiceKit

extension DictationPhase {
    /// Status color for the phase — used by the sidebar footer, menu bar, HUD.
    var statusColor: Color {
        switch self {
        case .idle: return .secondary
        case .listening: return AppTheme.positive
        case .transcribing: return AppTheme.progress
        }
    }
}

extension RecordingProgress {
    /// HUD tint for the amplitude meter + timer, keyed to how close we are to the
    /// active model's single-pass limit.
    var tint: Color {
        switch status {
        case .over: return AppTheme.danger
        case .warning: return AppTheme.warning
        case .normal, .streaming: return AppTheme.positive
        }
    }

    /// Color for the transient secondary label (near/over limit, minute mark).
    var secondaryColor: Color {
        switch status {
        case .over: return AppTheme.danger
        case .warning: return AppTheme.warning
        case .normal, .streaming: return AppTheme.warning   // minute-mark reminder
        }
    }
}
