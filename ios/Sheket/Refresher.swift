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

/// What the Status screen shows. Read-only values; decisions such as
/// staleness come from SheketCore.
struct StatusSnapshot: Sendable {
    /// False when the app-group container is unavailable.
    let storageAvailable: Bool
    /// False when no blocklist endpoint is configured.
    let refreshEnabled: Bool
    let generatedAt: String?
    let keywordCount: Int?
    let numberCount: Int?
    /// Entries in `call-directory.bin`; nil when missing or corrupt.
    let blockedEntryCount: Int?
    let lastReloadError: String?
    let isStale: Bool
}

/// Owns the blocklist store and runs every refresh, foreground and
/// background. All decisions (status codes, versions, ETags, staleness) are
/// SheketCore's; this type only does I/O and reloads the Call Directory.
actor Refresher {
    /// The store in the app-group container; nil when storage is unavailable.
    /// The container is created by the system, as in both extensions.
    private let store: BlocklistStore?
    private let blocklistURL = AppConfig.blocklistURL
    private var bootstrapped = false
    private var inFlight: Task<Void, Never>?

    init() {
        store = AppGroup.containerURL().map { BlocklistStore(directory: $0) }
    }

    /// The only refresh entry point. Concurrent callers share the run in
    /// progress: the actor is reentrant at every `await`, so isolation alone
    /// does not stop two runs from interleaving.
    func refresh() async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// The current state for the Status screen.
    func snapshot() -> StatusSnapshot {
        let list = store?.current()
        let state = store?.state()
        let now = Date()

        var blockedEntryCount: Int?
        if let store {
            let url = store.directory.appendingPathComponent(BlocklistStore.callDirectoryFileName)
            do {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                var count = 0
                try CallDirectoryEntries.forEachEntry(in: data) { _ in count += 1 }
                blockedEntryCount = count
            } catch {
                // Missing or corrupt: unknown.
                blockedEntryCount = nil
            }
        }

        return StatusSnapshot(
            storageAvailable: store != nil,
            refreshEnabled: blocklistURL != nil,
            generatedAt: list?.generatedAt,
            keywordCount: list?.smsKeywords.count,
            numberCount: list?.callNumbers.count,
            blockedEntryCount: blockedEntryCount,
            lastReloadError: state?.lastReloadError,
            isStale: state.map { RefreshPolicy.isStale(state: $0, now: now) } ?? false
        )
    }

    private func performRefresh() async {
        await bootstrapIfNeeded()
        guard let store else { return }

        var outcome: RefreshOutcome?
        if let url = blocklistURL {
            let request = RefreshPolicy.request(url: url, etag: store.state()?.etag)
            var status: Int?
            var body: Data?
            var etag: String?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                status = http?.statusCode
                body = data
                etag = http?.value(forHTTPHeaderField: "ETag")
            } catch {
                // Transport error or cancellation: everything stays nil and
                // RefreshPolicy.handle reports .failed.
            }
            outcome = try? RefreshPolicy.handle(
                status: status,
                body: body,
                etag: etag,
                store: store,
                now: Date()
            )
        }

        // Reload after a newly accepted list (REQ-4), and retry a reload
        // that failed earlier (spec section 7).
        if outcome == .accepted || store.state()?.lastReloadError != nil {
            await reloadCallDirectory()
        }
    }

    /// Runs once per process (REQ-1): repairs the store after an interrupted
    /// write and installs the bundled seed list if it is newer than the held
    /// one. `firstRunAt` is set by SheketCore (`repairIfNeeded` and `accept`
    /// set `firstRunAt ?? now`); the app never writes `state.json` itself.
    private func bootstrapIfNeeded() async {
        if bootstrapped { return }
        // Set before any await so a reentrant call cannot run it twice.
        bootstrapped = true
        guard let store else { return }

        var needsReload = (try? store.repairIfNeeded(now: Date())) ?? false
        if let url = Bundle.main.url(forResource: "seed-blocklist", withExtension: "json"),
           let seed = try? Data(contentsOf: url),
           (try? store.accept(seed, etag: nil, now: Date())) == .accepted {
            needsReload = true
        }
        if needsReload {
            await reloadCallDirectory()
        }
    }

    /// Asks iOS to reload the Call Directory extension and records the
    /// result; a nil error clears a previously recorded one.
    private func reloadCallDirectory() async {
        let message: String? = await withCheckedContinuation { continuation in
            CXCallDirectoryManager.sharedInstance.reloadExtension(
                withIdentifier: AppConfig.callDirectoryID
            ) { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        try? store?.recordReload(error: message)
    }
}
