import CallKit
import SwiftUI
import UIKit

/// Feeds the Status screen: the Refresher's snapshot and whether the user
/// has turned on the Call Directory extension. Reads only; no decisions.
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var callDirectoryStatus: CXCallDirectoryManager.EnabledStatus = .unknown

    private let refresher: Refresher

    init(refresher: Refresher) {
        self.refresher = refresher
    }

    func reload() async {
        snapshot = await refresher.snapshot()
        // Resumed with the raw value so only a plain Int crosses the
        // continuation; an error is reported as unknown.
        let rawStatus: Int = await withCheckedContinuation { continuation in
            CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(
                withIdentifier: AppConfig.callDirectoryID
            ) { status, error in
                let result: CXCallDirectoryManager.EnabledStatus = error == nil ? status : .unknown
                continuation.resume(returning: result.rawValue)
            }
        }
        callDirectoryStatus = CXCallDirectoryManager.EnabledStatus(rawValue: rawStatus) ?? .unknown
    }
}

/// The Status screen: which switches are off and where they are, and what
/// list the device holds (spec section 7).
struct StatusView: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let snapshot = model.snapshot, !snapshot.refreshEnabled || !snapshot.storageAvailable {
                Section {
                    if !snapshot.refreshEnabled {
                        Text("status.refresh.disabled")
                    }
                    if !snapshot.storageAvailable {
                        Text("status.storage.unavailable")
                    }
                }
            }

            Section("status.callBlocking.header") {
                switch model.callDirectoryStatus {
                case .enabled:
                    Text("status.callBlocking.enabled")
                case .disabled:
                    Text("status.callBlocking.disabled")
                    Text(callBlockingPath)
                    Button("status.callBlocking.openSettings") {
                        CXCallDirectoryManager.sharedInstance.openSettings { _ in }
                    }
                default:
                    // .unknown and any future status.
                    Text("status.callBlocking.unknown")
                }
                if let error = model.snapshot?.lastReloadError {
                    Text("status.callBlocking.reloadError \(error)")
                }
            }

            Section("status.sms.header") {
                Text("status.sms.instructions")
                Text(smsPath)
                Button("status.sms.openSettings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }

            Section("status.list.header") {
                if let snapshot = model.snapshot, let generatedAt = snapshot.generatedAt {
                    Text("status.list.generatedAt \(generatedAt)")
                    if let keywordCount = snapshot.keywordCount {
                        Text("status.list.keywords \(keywordCount)")
                    }
                    if let numberCount = snapshot.numberCount {
                        Text("status.list.numbers \(numberCount)")
                    }
                    if let blockedEntryCount = snapshot.blockedEntryCount {
                        Text("status.list.blockedEntries \(blockedEntryCount)")
                    }
                } else {
                    Text("status.list.none")
                }
                if model.snapshot?.isStale == true {
                    Text("status.list.stale")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.reload() }
    }

    // Settings paths are a view-layer #available choice per the design table:
    // iOS 16-17 "Settings > Phone > Call Blocking & Identification > Sheket"
    // and "Settings > Messages > Unknown & Spam > Sheket"; iOS 18+ moved both
    // under "Settings > Apps > Phone > ..." and "Settings > Apps > Messages > ...".
    // The iOS 18 paths are checked by the owner on devices (spec section 11, AC-5).

    private var callBlockingPath: LocalizedStringKey {
        if #available(iOS 18, *) {
            return "status.callBlocking.path.ios18"
        } else {
            return "status.callBlocking.path.ios16"
        }
    }

    private var smsPath: LocalizedStringKey {
        if #available(iOS 18, *) {
            return "status.sms.path.ios18"
        } else {
            return "status.sms.path.ios16"
        }
    }
}
