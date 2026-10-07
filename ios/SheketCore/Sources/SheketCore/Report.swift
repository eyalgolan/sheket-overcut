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

extension ReportOutcome {
    /// Maps the backend's responses (spec section 6.2: `202` accepted, `400`
    /// malformed with `{"error": "<field>"}`, `429` rate limited) to an
    /// outcome. `status` is nil when there was no HTTP response.
    ///
    /// A missing response or a 5xx is retryable without rate limiting. Any
    /// other status (for example 404 or 405, which the backend returns before
    /// any rate-limit quota is spent, or an unexpected 2xx/3xx) is treated as
    /// retryable too: one retry costs nothing, and the user then sees "not
    /// sent, try again later" (spec sections 6.2 and 7).
    ///
    /// For `400`, the field is the string `error` of a JSON object body, or
    /// nil if the body is missing, is not valid JSON, is not an object, or
    /// has no string `error`. This never throws.
    public static func from(status: Int?, body: Data?) -> ReportOutcome {
        switch status {
        case nil:
            return .retryable(rateLimited: false)
        case 202?:
            return .sent
        case 400?:
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let field = (object as? [String: Any])?["error"] as? String
            return .rejected(field)
        case 429?:
            return .retryable(rateLimited: true)
        default:
            // 5xx and every other status.
            return .retryable(rateLimited: false)
        }
    }
}

/// Retry policy for reports.
public enum ReportPolicy {
    /// Spec section 7 says a failed report is dropped after one retry and
    /// never queued, so 2 means the first attempt plus one retry, applied to
    /// every `.retryable` outcome. `.rejected` and `.sent` are never retried.
    public static let maxAttempts = 2
}

/// Builds the body of a report request (spec section 6.2).
public enum ReportRequest {
    /// The only platform this client sends.
    private static let platform = "ios"
    /// The backend's `MAX_TEXT_CHARS`. Python `len` counts code points, which
    /// equals `unicodeScalars.count`.
    private static let maxTextScalars = 1000
    /// Maximum `app_version` length, as in the backend's `_APP_VERSION`.
    private static let maxAppVersionScalars = 32

    /// Returns the JSON body of a report, or the first failing field.
    ///
    /// The body has the keys `install_id`, `platform`, `kind`, `sender`,
    /// `text` (only when non-nil) and `app_version`; `sender` is the
    /// normalised form (spec section 6.2). Fields are checked in the order of
    /// `_validate` in `backend/src/sheket/report.py`.
    ///
    /// There is no size check at run time: the backend's
    /// `MAX_BODY_BYTES = 16384` always fits. The largest valid body (1,000
    /// non-BMP scalars, 4 UTF-8 bytes each) is about 4.2 KB, and even if
    /// escaped as `\uXXXX` surrogate pairs the text alone is 12,000 bytes. A
    /// test pins this.
    public static func make(
        installID: String,
        kind: ReportKind,
        rawSender: String,
        text: String?,
        appVersion: String
    ) -> Result<Data, ReportFieldError> {
        guard isCanonicalInstallID(installID) else { return .failure(.installID) }

        // platform (the constant "ios") and kind (typed `ReportKind`) sit here
        // in the backend order and cannot fail.

        guard let sender = SenderNormalizer.normalize(rawSender) else { return .failure(.sender) }
        if kind == .call && !SenderNormalizer.isE164(sender) { return .failure(.sender) }
        // `report.py` also rejects a sender (and a text) that fails
        // `_is_utf8_encodable`, i.e. holds a lone surrogate. A Swift `String`
        // cannot hold a lone surrogate, so that check has no client-side
        // equivalent.

        // An empty text is allowed for SMS. Text is sent exactly as given,
        // not normalised or trimmed.
        if let text {
            if kind == .call {
                // The backend rejects a call report that carries text with
                // `400 {"error": "text"}`, its provisional answer to owner
                // Decision 6.
                return .failure(.text)
            }
            if text.unicodeScalars.count > maxTextScalars { return .failure(.text) }
        }

        guard isValidAppVersion(appVersion) else { return .failure(.appVersion) }

        var body: [String: String] = [
            "install_id": installID,
            "platform": platform,
            "kind": kind.rawValue,
            "sender": sender,
            "app_version": appVersion,
        ]
        if let text { body["text"] = text }
        do {
            return .success(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        } catch {
            preconditionFailure("a [String: String] is always valid JSON: \(error)")
        }
    }

    // MARK: - Private helpers

    /// Mirrors `_parse_install_id` in `backend/src/sheket/report.py`: 36
    /// characters in the canonical 8-4-4-4-12 form; braces, `urn:uuid:` and
    /// the form without hyphens are rejected.
    ///
    /// Stricter on purpose: the backend lowercases an uppercase ID, while the
    /// client must already send lowercase (#31 creates it with
    /// `UUID().uuidString.lowercased()`). Foundation's `UUID(uuidString:)` is
    /// not used because it accepts uppercase.
    private static func isCanonicalInstallID(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count == 36 else { return false }
        for i in 0..<u.count {
            switch i {
            case 8, 13, 18, 23:
                guard u[i] == "-" else { return false }
            default:
                switch u[i].value {
                case 0x30...0x39, 0x61...0x66: // "0"..."9", "a"..."f"
                    continue
                default:
                    return false
                }
            }
        }
        return true
    }

    /// The scalar-scan equivalent of
    /// `_APP_VERSION.fullmatch(r"[0-9A-Za-z.+\-]{1,32}")`, so `"1.0.0\n"` and
    /// `"1.0 beta"` fail.
    private static func isValidAppVersion(_ s: String) -> Bool {
        let u = s.unicodeScalars
        return (1...maxAppVersionScalars).contains(u.count) && u.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, // "0"..."9", "A"..."Z", "a"..."z"
                 0x2E, 0x2B, 0x2D: // ".", "+", "-"
                return true
            default:
                return false
            }
        }
    }
}
