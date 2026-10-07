import Foundation

/// Locates the shared app-group container.
///
/// Compiled into the app and both extensions. Each target's Info.plist
/// carries `SheketAppGroup`, set from the build configuration.
enum AppGroup {
    /// The app-group container, or nil when `SheketAppGroup` is missing or
    /// empty or the system has no container for it. Creates and writes
    /// nothing.
    static func containerURL() -> URL? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "SheketAppGroup") as? String,
              !identifier.isEmpty else {
            return nil
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
