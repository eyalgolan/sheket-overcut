import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Blocklist refresh for `GET <cloudfront-domain>/v1/blocklist.json`
// (spec sections 6.1 and 7).
//
// This file builds the request and maps a response onto `BlocklistStore`.
// It does no networking itself; the app performs the request and passes the
// status, body and ETag in.
//
// The current time is always passed in; nothing here reads the clock.

/// The result of handling one blocklist response.
public enum RefreshOutcome: Equatable {
    /// A newer list was stored. The app reloads the Call Directory.
    case accepted
    /// The list decoded, but its `version` is not greater than the held one.
    case ignoredNotNewer
    /// The server answered `304`: the held list is current.
    case notModified
    /// The list failed strict decoding; the previous list is kept.
    case rejected(BlocklistError)
    /// No usable response: a missing response, any status other than `200`
    /// or `304`, or a body over `RefreshPolicy.maxBodyBytes`. Nothing was
    /// changed.
    case failed
}

/// Request building, response handling and staleness for blocklist refresh.
public enum RefreshPolicy {
    /// Request timeout in seconds.
    public static let timeout: TimeInterval = 15
    /// Largest accepted response body: 5 MiB (spec section 7).
    public static let maxBodyBytes = 5 * 1024 * 1024
    /// A list is stale once the last successful check is more than 24 hours
    /// old (spec section 7).
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Builds the refresh request. The local cache is bypassed;
    /// `If-None-Match` is sent only for a non-empty `etag` (spec section 6.1).
    public static func request(url: URL, etag: String?) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    /// Applies one response to `store`. `status` is nil when there was no
    /// HTTP response; `etag` is the response's `ETag` header.
    ///
    /// - A body over `maxBodyBytes` is `.failed` whatever the status, and
    ///   nothing changes.
    /// - `200` offers the body to `store.accept`. An accepted or not-newer
    ///   list records a successful check; a rejected list does not.
    /// - `304` records a successful check.
    /// - Any other status, or none, is `.failed` and nothing changes.
    ///
    /// Throws only for the store's I/O errors.
    public static func handle(
        status: Int?,
        body: Data?,
        etag: String?,
        store: BlocklistStore,
        now: Date
    ) throws -> RefreshOutcome {
        if let body, body.count > maxBodyBytes { return .failed }

        switch status {
        case 200?:
            switch try store.accept(body ?? Data(), etag: etag, now: now) {
            case .accepted:
                try store.recordSuccess(now: now)
                return .accepted
            case .ignoredNotNewer:
                try store.recordSuccess(now: now)
                return .ignoredNotNewer
            case .rejected(let error):
                return .rejected(error)
            }
        case 304?:
            try store.recordSuccess(now: now)
            return .notModified
        default:
            // nil and every other status.
            return .failed
        }
    }

    /// True when the last successful check (a `200` or a `304`), or else
    /// the first stored list, is more than `staleAfter` before `now`. Exactly
    /// `staleAfter` is not stale. False when neither time is known.
    ///
    /// Staleness is measured from the last successful check, not from the
    /// list's `generated_at` (design Open Question 5).
    public static func isStale(state: BlocklistState, now: Date) -> Bool {
        guard let reference = state.lastSuccessAt ?? state.firstRunAt else { return false }
        return now.timeIntervalSince(reference) > staleAfter
    }
}
