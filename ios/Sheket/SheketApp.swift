import SwiftUI

/// The app shell: one Refresher shared by foreground and background
/// refreshes, and the Status screen as the root.
@main
@MainActor
struct SheketApp: App {
    private let refresher: Refresher
    @StateObject private var status: StatusModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let refresher = Refresher()
        self.refresher = refresher
        _status = StateObject(wrappedValue: StatusModel(refresher: refresher))
    }

    var body: some Scene {
        // Captured locally so the @Sendable background closure does not
        // capture self; Refresher is an actor and so Sendable.
        let refresher = refresher
        let status = status

        WindowGroup {
            // The single navigation root; #31 adds the Report and About
            // entries here.
            NavigationStack {
                StatusView(model: status)
                    .navigationTitle("app.title")
            }
            // Covers launch, when onChange may not fire for the first
            // .active. Refresher shares an in-flight run, so if both fire
            // together only one refresh happens.
            .task {
                await refresher.refresh()
                await status.reload()
            }
            // One-parameter form: the two-parameter form needs iOS 17.
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    // REQ-2: refresh on every foreground open. The first
                    // reload shows the Call Directory switch state at once,
                    // e.g. when returning from Settings.
                    Task {
                        await status.reload()
                        await refresher.refresh()
                        await status.reload()
                    }
                case .background:
                    // REQ-3
                    scheduleAppRefresh()
                default:
                    break
                }
            }
        }
        .backgroundTask(.appRefresh(AppConfig.refreshTaskID)) {
            // Schedule first so the next run is submitted even if this one
            // is cancelled; scheduleAppRefresh ignores submit errors.
            scheduleAppRefresh()
            await refresher.refresh()
        }
    }
}
