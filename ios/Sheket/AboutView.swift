import SwiftUI

/// The About screen: what the app does, what a report sends and how long it
/// is kept, and the app version. Static text only; no state, no I/O.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("about.what.body")
                // Spec section 4: messages and calls from contacts are never seen.
                Text("about.contacts.body")
            } header: {
                Text("about.what.header")
            }

            Section {
                Text("about.report.body")
                Text("about.retention.body")
            } header: {
                Text("about.report.header")
            }

            Section {
                // Placeholder privacy wording, pending the owner's and a
                // lawyer's text (spec section 8, risk 6).
                Text("about.privacy.placeholder")
                // MARKETING_VERSION; catalog key "about.version %@".
                Text("about.version \(AppConfig.appVersion)")
            }
        }
        .navigationTitle("about.title")
    }
}
