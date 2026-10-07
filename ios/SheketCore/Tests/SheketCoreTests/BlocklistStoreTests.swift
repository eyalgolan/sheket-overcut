import Foundation
import SheketCore
import XCTest

/// Tests for `BlocklistStore` (spec sections 6.1 and 7): accepting, ignoring
/// and rejecting lists, the ETag rules, repair after an interrupted write,
/// and the success and reload bookkeeping.
final class BlocklistStoreTests: XCTestCase {
    private static let seedFile = "seed-blocklist.json"
    private static let testFile = "test-blocklist.json"
    private static let seedVersion: Int64 = 1_791_149_668
    private static let testVersion: Int64 = 1_791_201_600

    /// `state.json` is private to the store; tests read it by path.
    private static let stateFileName = "state.json"

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_800_003_600)

    private var directory: URL!
    private var store: BlocklistStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocklistStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = BlocklistStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        store = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func bytes(_ name: String) -> Data? {
        try? Data(contentsOf: url(name))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// The bytes of the three store files, nil for a missing file.
    private func snapshot() -> [Data?] {
        [
            bytes(BlocklistStore.blocklistFileName),
            bytes(BlocklistStore.callDirectoryFileName),
            bytes(Self.stateFileName),
        ]
    }

    /// The values stored in `call-directory.bin`.
    private func storedEntries() throws -> [Int64] {
        let data = try XCTUnwrap(bytes(BlocklistStore.callDirectoryFileName))
        var entries: [Int64] = []
        try CallDirectoryEntries.forEachEntry(in: data) { entries.append($0) }
        return entries
    }

    /// `state.json` decoded directly from disk, without `store.state()`'s
    /// ETag clearing.
    private func stateOnDisk() throws -> BlocklistState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(BlocklistState.self, from: XCTUnwrap(bytes(Self.stateFileName)))
    }

    /// Overwrites `state.json` in the store's own format.
    private func writeState(_ state: BlocklistState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(state).write(to: url(Self.stateFileName))
    }

    /// The seed document, changed by `change`, re-serialised.
    private func mutatedSeed(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Contract.data(Self.seedFile)) as? [String: Any]
        )
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - AC-1: accepting the seed

    func testAcceptSeedIntoEmptyStore() throws {
        let seed = try Contract.data(Self.seedFile)
        let seedList = try Contract.blocklist(Self.seedFile)
        XCTAssertEqual(seedList.version, Self.seedVersion)

        XCTAssertEqual(try store.accept(seed, etag: nil, now: t0), .accepted)

        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), seed, "blocklist.json must be the document byte for byte")
        XCTAssertTrue(exists(BlocklistStore.callDirectoryFileName))
        XCTAssertTrue(exists(Self.stateFileName))
        XCTAssertEqual(try storedEntries(), CallDirectoryEntries.build(seedList))
        XCTAssertEqual(store.current(), seedList)

        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.seedVersion)
        XCTAssertEqual(state.entriesVersion, Self.seedVersion)
        XCTAssertEqual(state.firstRunAt, t0)
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertNil(state.etag)
        XCTAssertNil(state.lastReloadError)
    }

    func testEmptyStoreHasNothing() {
        XCTAssertNil(store.current())
        XCTAssertNil(store.state())
        XCTAssertEqual(snapshot(), [nil, nil, nil])
    }

    // MARK: - AC-2: only newer versions

    func testNewerAcceptedOlderIgnored() throws {
        let seed = try Contract.data(Self.seedFile)
        let test = try Contract.data(Self.testFile)
        let testList = try Contract.blocklist(Self.testFile)
        XCTAssertEqual(testList.version, Self.testVersion)

        XCTAssertEqual(try store.accept(seed, etag: nil, now: t0), .accepted)
        XCTAssertEqual(try store.accept(test, etag: "\"v2\"", now: t1), .accepted)

        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), test)
        XCTAssertEqual(try storedEntries(), CallDirectoryEntries.build(testList))
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.testVersion)
        XCTAssertEqual(state.entriesVersion, Self.testVersion)
        XCTAssertEqual(state.firstRunAt, t0, "firstRunAt must keep the first accept's time")

        let before = snapshot()
        XCTAssertEqual(try store.accept(seed, etag: "\"old\"", now: t1), .ignoredNotNewer)
        XCTAssertEqual(snapshot(), before, "an older list must write nothing, not even its ETag")
    }

    func testSameVersionIgnored() throws {
        let seed = try Contract.data(Self.seedFile)
        XCTAssertEqual(try store.accept(seed, etag: "x", now: t0), .accepted)

        let before = snapshot()
        XCTAssertEqual(try store.accept(seed, etag: "y", now: t1), .ignoredNotNewer)
        XCTAssertEqual(snapshot(), before)
    }

    // MARK: - AC-3: invalid documents

    func testWrongSchemaRejectedPreviousKept() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        let before = snapshot()

        let schema2 = try mutatedSeed { $0["schema"] = 2 }
        XCTAssertEqual(try store.accept(schema2, etag: "y", now: t1), .rejected(.invalid(field: "schema")))
        XCTAssertEqual(snapshot(), before)
    }

    func testExtraKeyRejectedPreviousKept() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        let before = snapshot()

        let extra = try mutatedSeed { $0["extra"] = true }
        XCTAssertEqual(try store.accept(extra, etag: "y", now: t1), .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), before)
    }

    func testMalformedRejectedPreviousKept() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        let before = snapshot()

        XCTAssertEqual(try store.accept(Data("{not json".utf8), etag: "y", now: t1),
                       .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), before)
    }

    func testInvalidIntoEmptyStoreWritesNothing() throws {
        let schema2 = try mutatedSeed { $0["schema"] = 2 }
        XCTAssertEqual(try store.accept(schema2, etag: "x", now: t0), .rejected(.invalid(field: "schema")))
        XCTAssertEqual(snapshot(), [nil, nil, nil])
        XCTAssertNil(store.current())
        XCTAssertNil(store.state())
    }

    // MARK: - AC-4: ETag

    func testETagStoredAndCleared() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        XCTAssertEqual(store.state()?.etag, "x")

        XCTAssertEqual(try store.accept(Contract.data(Self.testFile), etag: nil, now: t1), .accepted)
        let state = try XCTUnwrap(store.state())
        XCTAssertNil(state.etag)
    }

    func testCorruptListClearsETag() throws {
        let seed = try Contract.data(Self.seedFile)
        XCTAssertEqual(try store.accept(seed, etag: "x", now: t0), .accepted)

        try Data("{not json".utf8).write(to: url(BlocklistStore.blocklistFileName))

        XCTAssertNil(store.current())
        XCTAssertNil(try stateOnDisk().etag, "current() must clear the ETag on disk")
        let state = try XCTUnwrap(store.state())
        XCTAssertNil(state.etag)
        XCTAssertEqual(state.version, Self.seedVersion, "only the ETag is cleared")
        XCTAssertEqual(state.firstRunAt, t0)

        // The corrupt list counts as version 0, so the seed is taken again.
        XCTAssertEqual(try store.accept(seed, etag: nil, now: t1), .accepted)
        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), seed)
        XCTAssertEqual(store.current(), try Contract.blocklist(Self.seedFile))
    }

    func testMissingListClearsETagInState() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        try FileManager.default.removeItem(at: url(BlocklistStore.blocklistFileName))

        XCTAssertNil(try XCTUnwrap(store.state()).etag)
        XCTAssertNil(try stateOnDisk().etag, "state() must clear the ETag on disk")
    }

    // MARK: - AC-5: repair

    func testRepairNotNeededAfterAccept() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        let before = snapshot()
        XCTAssertFalse(try store.repairIfNeeded())
        XCTAssertEqual(snapshot(), before)
    }

    func testRepairOnEmptyStore() throws {
        XCTAssertFalse(try store.repairIfNeeded())
        XCTAssertEqual(snapshot(), [nil, nil, nil])
    }

    func testRepairMissingState() throws {
        let testList = try Contract.blocklist(Self.testFile)
        XCTAssertEqual(try store.accept(Contract.data(Self.testFile), etag: "x", now: t0), .accepted)
        try FileManager.default.removeItem(at: url(Self.stateFileName))

        XCTAssertTrue(try store.repairIfNeeded())

        XCTAssertTrue(exists(Self.stateFileName))
        XCTAssertEqual(try storedEntries(), CallDirectoryEntries.build(testList))
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.testVersion)
        XCTAssertEqual(state.entriesVersion, Self.testVersion)
        XCTAssertNil(state.etag, "no old state, so no ETag to keep")
        XCTAssertFalse(try store.repairIfNeeded(), "a repaired store needs no further repair")
    }

    func testRepairVersionMismatchClearsETag() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.testFile), etag: "x", now: t0), .accepted)
        try store.recordSuccess(now: t1)
        try store.recordReload(error: "boom")
        try writeState(BlocklistState(
            version: Self.seedVersion,
            entriesVersion: Self.seedVersion,
            etag: "x",
            lastSuccessAt: t1,
            firstRunAt: t0,
            lastReloadError: "boom"
        ))

        XCTAssertTrue(try store.repairIfNeeded())

        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.testVersion)
        XCTAssertEqual(state.entriesVersion, Self.testVersion)
        XCTAssertNil(state.etag, "the ETag belonged to another version")
        XCTAssertEqual(state.lastSuccessAt, t1)
        XCTAssertEqual(state.firstRunAt, t0)
        XCTAssertEqual(state.lastReloadError, "boom")
    }

    func testRepairEntriesMismatchRebuildsEntriesKeepsETag() throws {
        let testList = try Contract.blocklist(Self.testFile)
        XCTAssertEqual(try store.accept(Contract.data(Self.testFile), etag: "x", now: t0), .accepted)
        try FileManager.default.removeItem(at: url(BlocklistStore.callDirectoryFileName))
        try writeState(BlocklistState(
            version: Self.testVersion,
            entriesVersion: 1,
            etag: "x",
            firstRunAt: t0
        ))

        XCTAssertTrue(try store.repairIfNeeded())

        XCTAssertTrue(exists(BlocklistStore.callDirectoryFileName))
        XCTAssertEqual(try storedEntries(), CallDirectoryEntries.build(testList))
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.testVersion)
        XCTAssertEqual(state.entriesVersion, Self.testVersion)
        XCTAssertEqual(state.etag, "x", "the ETag belongs to the stored list's version")
        XCTAssertEqual(state.firstRunAt, t0)
    }

    // MARK: - recordSuccess / recordReload

    func testRecordSuccess() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
        let listBefore = bytes(BlocklistStore.blocklistFileName)
        let entriesBefore = bytes(BlocklistStore.callDirectoryFileName)

        try store.recordSuccess(now: t1)

        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.lastSuccessAt, t1)
        XCTAssertEqual(state.firstRunAt, t0)
        XCTAssertEqual(state.etag, "x")
        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), listBefore)
        XCTAssertEqual(bytes(BlocklistStore.callDirectoryFileName), entriesBefore)
    }

    func testRecordReloadSetsAndClearsError() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: nil, now: t0), .accepted)

        try store.recordReload(error: "extension disabled")
        XCTAssertEqual(store.state()?.lastReloadError, "extension disabled")

        // Survives a later accept.
        XCTAssertEqual(try store.accept(Contract.data(Self.testFile), etag: nil, now: t1), .accepted)
        XCTAssertEqual(store.state()?.lastReloadError, "extension disabled")

        try store.recordReload(error: nil)
        let state = try XCTUnwrap(store.state())
        XCTAssertNil(state.lastReloadError)
    }

    func testRecordOnEmptyStoreDoesNothing() throws {
        try store.recordSuccess(now: t0)
        try store.recordReload(error: "boom")
        XCTAssertEqual(snapshot(), [nil, nil, nil])
        XCTAssertNil(store.state())
    }
}
