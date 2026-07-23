// Single source of truth for the app version. Kept in VoixfulKit so both the
// UI and any packaging step read the same value. Keep in sync with the app's
// Info.plist CFBundleShortVersionString.

public enum AppInfo {
    public static let version = "0.1.0"
    public static let name = "Voixful"
}
