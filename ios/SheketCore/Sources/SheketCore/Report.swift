import Foundation

// Report types for `POST <function-url>/v1/reports`.
//
// This file is a field-by-field port of `_validate` in
// `backend/src/sheket/report.py`, checking fields in the same order:
// install_id, platform, kind, sender, text, app_version.
//
// The binding definition is spec section 6.2 (`docs/spec.md`); section 7
// holds the retry rule.
//
// Patterns are checked by scanning Unicode scalars, not with
// `NSRegularExpression`, because an anchored ICU `$` also accepts a trailing
// newline, as in `SenderNormalizer.swift`.
//
// There is no networking, storage or UI here; those belong to #31.

/// What is being reported: a call or an SMS.
///
/// The raw values are the backend's `KINDS`. Because the type is closed, the
/// `kind` check in `_validate` cannot fail on the client.
public enum ReportKind: String, Equatable {
    case call
    case sms
}

/// The field that made a report invalid.
///
/// Each raw value is the field name the backend returns in
/// `400 {"error": "<field>"}`.
///
/// `body`, `platform` and `kind` have no case because they cannot fail on the
/// client: the client builds the body itself, platform is the constant
/// `"ios"`, and kind is typed.
public enum ReportFieldError: String, Error, Equatable {
    case installID = "install_id"
    case sender
    case text
    case appVersion = "app_version"
}

/// The result of sending one report.
public enum ReportOutcome: Equatable {
    /// The server accepted the report (`202`).
    case sent
    /// The server rejected the report as malformed (`400`). The associated
    /// value is the field from the server's `{"error": "<field>"}`, or nil if
    /// the body does not carry a string `error`. A rejected report is never
    /// retried.
    case rejected(String?)
    /// The report was not accepted but may be tried again. `rateLimited` is
    /// true when the server answered `429`.
    case retryable(rateLimited: Bool)
}

/// Retry policy for reports.
public enum ReportPolicy {
    /// Spec section 7 says a failed report is dropped after one retry and
    /// never queued, so 2 means the first attempt plus one retry, applied to
    /// every `.retryable` outcome. `.rejected` and `.sent` are never retried.
    public static let maxAttempts = 2
}
