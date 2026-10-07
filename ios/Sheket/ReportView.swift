import Foundation
import SheketCore
import SwiftUI

extension AppConfig {
    /// The report endpoint from Info.plist's `SheketReportURL`, or nil when
    /// the key is missing or empty, or the value is not an `https` URL with a
    /// host. Nil disables Send (REQ-5); it never crashes the app.
    static let reportURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SheketReportURL") as? String,
              !value.isEmpty,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }()

    /// The `app_version` sent with reports: `CFBundleShortVersionString`,
    /// i.e. `MARKETING_VERSION`. An empty value fails `ReportRequest.make`
    /// with `.appVersion`, which disables Send.
    static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

/// The Report screen: one report of a call or SMS sender (spec section 6.2).
///
/// All state is in-memory `@State`; nothing is stored or queued (spec
/// section 7). Validation and response handling are SheketCore's
/// (`ReportRequest`, `ReportOutcome`, `ReportPolicy`); this view only shows
/// them and does the I/O.
struct ReportView: View {
    let installID: String

    @State private var rawSender = ""
    @State private var kind: ReportKind = .sms
    @State private var includeText = false
    @State private var text = ""
    @State private var isSending = false
    @State private var result: ReportResult?

    var body: some View {
        Form {
            Section {
                TextField("report.sender.placeholder", text: $rawSender)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                switch fieldError {
                case .sender?:
                    // No error for an empty field the user has not typed in yet.
                    if !rawSender.isEmpty {
                        errorText("report.error.sender")
                    }
                case .installID?, .appVersion?:
                    errorText("report.error.config")
                default:
                    EmptyView()
                }
            }

            Section {
                // A segmented picker does not reliably honour .disabled on one
                // segment, so the whole picker is disabled while Call is not
                // allowed. kindBinding still enforces the rule as a backstop.
                Picker("report.kind.label", selection: kindBinding) {
                    Text("report.kind.sms").tag(ReportKind.sms)
                    Text("report.kind.call").tag(ReportKind.call)
                }
                .pickerStyle(.segmented)
                .disabled(!callAllowed)
            } footer: {
                if !callAllowed {
                    Text("report.kind.callUnavailable")
                }
            }

            if kind == .sms {
                Section {
                    Toggle("report.includeText", isOn: $includeText)
                    if includeText {
                        TextField("report.text.placeholder", text: $text, axis: .vertical)
                        if fieldError == .text {
                            errorText("report.error.text")
                        }
                    }
                }
            }

            Section {
                if AppConfig.reportURL == nil {
                    errorText("report.error.noURL")
                }
                // Only the button is disabled while sending: the fields stay
                // editable and the UI is never blocked on the result (spec
                // section 6.2).
                Button("report.send") { startSend() }
                    .disabled(!canSend)
                if isSending {
                    ProgressView()
                }
                if let result {
                    Text(result.key)
                }
            }
        }
        // One-parameter form: the two-parameter form needs iOS 17. A call
        // report needs an E.164 sender, so editing the sender away from one
        // falls back to SMS.
        .onChange(of: rawSender) { _ in
            if kind == .call && !callAllowed {
                kind = .sms
            }
        }
        .navigationTitle("report.title")
    }

    // MARK: - Derived values

    /// A call report needs an E.164 sender; `ReportRequest.make` fails a
    /// call with any other sender.
    private var callAllowed: Bool {
        SenderNormalizer.normalize(rawSender).map(SenderNormalizer.isE164) ?? false
    }

    /// Text is sent only for SMS and only when the user ticks "include the
    /// message text" (spec section 6.2).
    private var effectiveText: String? {
        (kind == .sms && includeText) ? text : nil
    }

    /// Recomputed on every body evaluation, so errors update as the user
    /// types.
    private var validation: Result<Data, ReportFieldError> {
        ReportRequest.make(
            installID: installID,
            kind: kind,
            rawSender: rawSender,
            text: effectiveText,
            appVersion: AppConfig.appVersion
        )
    }

    private var fieldError: ReportFieldError? {
        if case .failure(let error) = validation { return error }
        return nil
    }

    private var canSend: Bool {
        guard AppConfig.reportURL != nil, !isSending, case .success = validation else { return false }
        return true
    }

    /// Ignores a switch to `.call` unless the sender allows it.
    private var kindBinding: Binding<ReportKind> {
        Binding(
            get: { kind },
            set: { newKind in
                if newKind == .call && !callAllowed { return }
                kind = newKind
            }
        )
    }

    private func errorText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.footnote)
            .foregroundStyle(.red)
    }

    // MARK: - Sending

    private func startSend() {
        guard !isSending,
              let url = AppConfig.reportURL,
              case .success(let body) = validation else {
            return
        }
        isSending = true
        result = nil
        // A plain Task, not `.task`, so leaving the screen does not cancel a
        // send in progress.
        Task { @MainActor in
            let outcome = await Self.send(body: body, to: url)
            result = ReportResult.from(outcome)
            isSending = false
        }
    }

    /// Posts the report, retrying a `.retryable` outcome once about 2 s
    /// later; after that the report is dropped (spec section 7). Nothing is
    /// stored or queued.
    private static func send(body: Data, to url: URL) async -> ReportOutcome {
        var outcome = ReportOutcome.from(status: nil, body: nil)
        for attempt in 1...ReportPolicy.maxAttempts {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                outcome = ReportOutcome.from(status: (response as? HTTPURLResponse)?.statusCode, body: data)
            } catch {
                // Transport error: no HTTP response.
                outcome = ReportOutcome.from(status: nil, body: nil)
            }
            guard case .retryable = outcome, attempt < ReportPolicy.maxAttempts else { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return outcome
    }
}

/// What the user is told after a send. The mapping from HTTP responses is
/// `ReportOutcome`'s; this only picks the message.
private enum ReportResult {
    case sent
    case rateLimited
    case notSent

    var key: LocalizedStringKey {
        switch self {
        case .sent: return "report.result.sent"
        case .rateLimited: return "report.result.rateLimited"
        case .notSent: return "report.result.notSent"
        }
    }

    static func from(_ outcome: ReportOutcome) -> ReportResult {
        switch outcome {
        case .sent:
            return .sent
        case .retryable(rateLimited: true):
            return .rateLimited
        case .retryable(rateLimited: false), .rejected:
            return .notSent
        }
    }
}
