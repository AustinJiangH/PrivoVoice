// Single source of truth for the app version. Kept in PrivoVoiceKit so both the
// UI and any packaging step read the same value. Keep in sync with the app's
// Info.plist CFBundleShortVersionString.
//
// Also the build *flavor*: `make-app.sh --release` (what `make-dmg.sh` ships)
// stamps `PrivoVoiceFlavor = release` into the bundle's Info.plist; every other
// build — a plain `make-app.sh`, `swift run`, tests — is a dev build. A dev build
// is its own app ("PrivoVoice Dev", separate bundle id) with its own settings
// folder, so it can sit next to an installed release without either one
// clobbering the other. Downloaded models and formatters stay shared.

import Foundation

public enum AppInfo {
    public static let version = "0.2.0"
    public static let name = "PrivoVoice"

    /// Bundle ids of the two flavors (must match `make-app.sh`).
    public static let releaseBundleID = "com.privovoice.app"
    public static let devBundleID = "com.privovoice.app.dev"

    /// `true` for anything not stamped as a release build.
    public static let isDevBuild: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "PrivoVoiceFlavor") as? String) != "release"

    /// Short git commit the dev bundle was built from (`+dirty` if the tree had
    /// uncommitted changes), or `nil` when unknown (`swift run`, release).
    public static let gitCommit: String? =
        Bundle.main.object(forInfoDictionaryKey: "PrivoVoiceGitCommit") as? String

    /// "PrivoVoice" or "PrivoVoice Dev".
    public static var displayName: String { isDevBuild ? "\(name) Dev" : name }

    /// "0.2.0", or "0.2.0 (dev · abc1234)" for a dev build.
    public static var versionDescription: String {
        guard isDevBuild else { return version }
        return "\(version) (dev\(gitCommit.map { " · \($0)" } ?? ""))"
    }

    /// Bundle id of the *other* flavor — used to warn when both are running,
    /// since both would react to the same global hotkeys.
    public static var otherFlavorBundleID: String { isDevBuild ? releaseBundleID : devBundleID }

    /// `~/Library/Application Support/PrivoVoice` (release) or
    /// `…/PrivoVoice Dev` (dev): settings, usage totals, dictation log.
    public static var supportDirectory: URL {
        supportDirectory(named: displayName)
    }

    private static func supportDirectory(named folder: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: folder, directoryHint: .isDirectory)
    }

    /// First launch of a dev build: start from a copy of the release build's
    /// settings (selected model, hotkey, onboarding done) instead of a blank
    /// slate. Never touches the release folder; no-op once the dev settings
    /// exist or on a release build.
    public static func seedDevSettingsIfNeeded() {
        guard isDevBuild else { return }
        let fm = FileManager.default
        let devSettings = supportDirectory.appending(path: "settings.json")
        let releaseSettings = supportDirectory(named: name).appending(path: "settings.json")
        guard !fm.fileExists(atPath: devSettings.path),
              fm.fileExists(atPath: releaseSettings.path) else { return }
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.copyItem(at: releaseSettings, to: devSettings)
    }
}
