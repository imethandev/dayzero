import Foundation

enum AppInfo {
    /// Set at build time from Config/Signing.xcconfig (BUNDLE_ID_PREFIX), so forks use their own ID.
    static let bundleID = Bundle.main.bundleIdentifier ?? "DayZero"
}
