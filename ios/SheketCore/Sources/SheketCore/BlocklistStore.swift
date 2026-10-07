import Foundation

// On-disk storage for the current blocklist and the files derived from it
// (spec sections 6.1 and 7).
//
// The store keeps three files in one directory:
//
// - `blocklist.json`: the accepted document, byte for byte as downloaded.
// - `call-directory.bin`: `CallDirectoryEntries.encode` of that list, read by
//   the Call Directory extension.
// - `state.json`: `BlocklistState`, the bookkeeping around the list.
//
// Rules this file enforces:
//
// - A malformed or wrong-schema list is rejected whole and nothing is
//   written; the previous list is kept (spec section 7).
// - A list whose `version` is not greater than the held one is ignored
//   (spec section 6.1), and nothing is written, not even its ETag.
// - The ETag is only meaningful while `blocklist.json` exists: if the list is
//   missing or unreadable, the stored ETag is cleared so the next request does
//   not send `If-None-Match` and get a `304` for a list the device lacks.
// - Writes are atomic and go in the order `blocklist.json`,
//   `call-directory.bin`, `state.json`. An interrupted sequence leaves
//   `state.json` behind the list, which `repairIfNeeded()` detects and fixes.
//
// The current time is always passed in; nothing here reads the clock.

/// The outcome of offering a downloaded document to `BlocklistStore.accept`.
public enum AcceptResult: Equatable {
    /// The list was stored and the derived files rebuilt.
    case accepted
    /// The list decoded, but its `version` is not greater than the held one.
    /// Nothing was written.
    case ignoredNotNewer
    /// The list failed strict decoding. Nothing was written; the previous
    /// list is kept.
    case rejected(BlocklistError)
}

/// Bookkeeping stored next to the blocklist in `state.json`.
public struct BlocklistState: Codable, Equatable {
    /// `version` of the list in `blocklist.json`.
    public var version: Int64
    /// `version` of the list `call-directory.bin` was built from.
    public var entriesVersion: Int64
    /// ETag of the stored list, sent as `If-None-Match`. Nil when unknown.
    public var etag: String?
    /// When a refresh last completed (a `200` stored or a `304`).
    public var lastSuccessAt: Date?
    /// When the first list was stored on this device.
    public var firstRunAt: Date?
    /// The last Call Directory reload error, or nil after a successful
    /// reload.
    public var lastReloadError: String?

    public init(
        version: Int64,
        entriesVersion: Int64,
        etag: String? = nil,
        lastSuccessAt: Date? = nil,
        firstRunAt: Date? = nil,
        lastReloadError: String? = nil
    ) {
        self.version = version
        self.entriesVersion = entriesVersion
        self.etag = etag
        self.lastSuccessAt = lastSuccessAt
        self.firstRunAt = firstRunAt
        self.lastReloadError = lastReloadError
    }
}

/// Stores the blocklist, its Call Directory entries and `BlocklistState` in
/// one directory. See the file-level documentation above for the rules.
public final class BlocklistStore {
    public static let blocklistFileName = "blocklist.json"
    public static let callDirectoryFileName = "call-directory.bin"
    private static let stateFileName = "state.json"

    /// Sorted keys so the same state always encodes to the same bytes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// The directory holding the store's files. It must already exist.
    public let directory: URL

    /// Does no I/O; files are read and written on demand.
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Reading

    /// The stored list, or nil when `blocklist.json` is missing or does not
    /// decode. When nil, a stored ETag is cleared.
    public func current() -> Blocklist? {
        if let list = readList()?.list {
            return list
        }
        try? clearETagIfListMissing()
        return nil
    }

    /// The stored state, or nil when `state.json` is missing or does not
    /// decode. When the list is missing, the ETag is cleared on disk and the
    /// returned state has a nil `etag`.
    public func state() -> BlocklistState? {
        guard var state = readState() else { return nil }
        if state.etag != nil, readList() == nil {
            state.etag = nil
            try? writeState(state)
        }
        return state
    }

    // MARK: - Writing

    /// Offers a downloaded document to the store.
    ///
    /// The document is decoded strictly; a rejected or not-newer list writes
    /// nothing. An accepted list is stored unchanged, the Call Directory
    /// entries are rebuilt, and the state records the new version and `etag`
    /// (nil clears it). `lastSuccessAt` is not changed here; call
    /// `recordSuccess(now:)` once the refresh completes. `firstRunAt` is set
    /// to `now` if it was not already set.
    ///
    /// Throws only for I/O errors.
    public func accept(_ data: Data, etag: String?, now: Date) throws -> AcceptResult {
        let list: Blocklist
        do {
            list = try BlocklistDecoder.decode(data)
        } catch let error as BlocklistError {
            return .rejected(error)
        }

        let held = readList()?.list.version ?? 0
        guard list.version > held else { return .ignoredNotNewer }

        let previous = readState()
        try write(data, to: Self.blocklistFileName)
        try writeDerived(list: list, state: BlocklistState(
            version: list.version,
            entriesVersion: list.version,
            etag: etag,
            lastSuccessAt: previous?.lastSuccessAt,
            firstRunAt: previous?.firstRunAt ?? now,
            lastReloadError: previous?.lastReloadError
        ))
        return .accepted
    }

    /// Records a completed refresh (a stored list or a `304`). Does nothing
    /// when there is no state yet.
    public func recordSuccess(now: Date) throws {
        guard var state = state() else { return }
        state.lastSuccessAt = now
        state.firstRunAt = state.firstRunAt ?? now
        try writeState(state)
    }

    /// Records the result of the last Call Directory reload: an error
    /// description, or nil on success. Does nothing when there is no state
    /// yet.
    public func recordReload(error: String?) throws {
        guard var state = state() else { return }
        state.lastReloadError = error
        try writeState(state)
    }

    /// Rebuilds `call-directory.bin` and `state.json` from the stored list
    /// when they are missing, undecodable or behind it, for example after an
    /// interrupted `accept`. Returns true if anything was rewritten.
    ///
    /// The old state's timestamps and reload error are kept. Its ETag is kept
    /// only when it belongs to the stored list's version.
    public func repairIfNeeded() throws -> Bool {
        guard let list = readList()?.list else {
            try clearETagIfListMissing()
            return false
        }
        let old = readState()
        if let old, old.version == list.version, old.entriesVersion == list.version {
            return false
        }
        try writeDerived(list: list, state: BlocklistState(
            version: list.version,
            entriesVersion: list.version,
            etag: old?.version == list.version ? old?.etag : nil,
            lastSuccessAt: old?.lastSuccessAt,
            firstRunAt: old?.firstRunAt,
            lastReloadError: old?.lastReloadError
        ))
        return true
    }

    // MARK: - Private

    /// Every write goes through here: atomic, and readable by the Call
    /// Directory extension once the device has been unlocked after boot.
    private func write(_ data: Data, to name: String) throws {
        try data.write(
            to: directory.appendingPathComponent(name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func writeState(_ state: BlocklistState) throws {
        try write(Self.encoder.encode(state), to: Self.stateFileName)
    }

    /// Nil when `state.json` is missing or does not decode. Never throws.
    private func readState() -> BlocklistState? {
        let url = directory.appendingPathComponent(Self.stateFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(BlocklistState.self, from: data)
    }

    /// Nil when `blocklist.json` is missing or fails strict decoding.
    private func readList() -> (data: Data, list: Blocklist)? {
        let url = directory.appendingPathComponent(Self.blocklistFileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? BlocklistDecoder.decode(data) else { return nil }
        return (data, list)
    }

    /// Writes the Call Directory entries for `list`, then `state`.
    private func writeDerived(list: Blocklist, state: BlocklistState) throws {
        let entries = CallDirectoryEntries.encode(CallDirectoryEntries.build(list))
        try write(entries, to: Self.callDirectoryFileName)
        try writeState(state)
    }

    /// Clears the stored ETag when there is no readable list, leaving the
    /// other fields untouched.
    private func clearETagIfListMissing() throws {
        guard readList() == nil, var state = readState(), state.etag != nil else { return }
        state.etag = nil
        try writeState(state)
    }
}
