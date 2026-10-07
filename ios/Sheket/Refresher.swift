import BackgroundTasks
import CallKit
import Foundation
import SheketCore

/// Identifiers and endpoints read from the app's bundle.
///
/// The identifiers match the build configuration: the app's bundle ID is
/// `$(SHEKET_BUNDLE_ID_PREFIX)`, the Call Directory extension's is
/// `$(SHEKET_BUNDLE_ID_PREFIX).calldirectory`, and Info.plist permits the
/// background task `$(SHEKET_BUNDLE_ID_PREFIX).refresh`.
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? ""
    static let callDirectoryID = bundleID + ".calldirectory"
    static let refreshTaskID = bundleID + ".refresh"

    /// The blocklist endpoint from Info.plist's `SheketBlocklistURL`, or nil
    /// when the key is missing or empty, or the value is not an `https` URL
    /// with a host. A configuration check only.
    static let blocklistURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SheketBlocklistURL") as? String,
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }()
}

/// Asks iOS for a background refresh no earlier than 15 minutes from now.
func scheduleAppRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskID)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    // Errors are ignored on purpose: submit throws in the Simulator and when
    // Background App Refresh is off, and a foreground open always refreshes
    // anyway (spec sections 4 and 7).
    try? BGTaskScheduler.shared.submit(request)
}
