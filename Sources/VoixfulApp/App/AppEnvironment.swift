// The shared object graph: one instance owns every VoixfulKit service, used by
// both the SwiftUI scenes and the AppKit delegate. A single `@MainActor`
// singleton keeps the SwiftUI side and the AppKit side (hotkey, HUD, paste)
// looking at the same state.

import Foundation
import Observation
import VoixfulKit

@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let store: ModelStore
    let downloader: ModelDownloader
    let appState: AppState
    let dictation: DictationController
    let route = Router()

    private init() {
        let settings = AppSettings()
        let store = ModelStore(settings: settings)
        self.settings = settings
        self.store = store
        self.downloader = ModelDownloader(store: store, settings: settings)
        let appState = AppState()
        self.appState = appState
        self.dictation = DictationController(appState: appState, settings: settings, store: store)
    }
}
