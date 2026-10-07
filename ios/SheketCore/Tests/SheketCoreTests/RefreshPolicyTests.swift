import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SheketCore
import XCTest

/// Tests for `RefreshPolicy` (spec sections 6.1 and 7): the request, the
/// mapping of each response onto `BlocklistStore`, and staleness.
final class RefreshPolicyTests: XCTestCase {
    private static let seedFile = "seed-blocklist.json"
    private static let testFile = "test-blocklist.json"
    private static let seedVersion: Int64 = 1_791_149_668
    private static let testVersion: Int64 = 1_791_201_600

    /// `state.json` is private to the store; tests read it by path.
    private static let stateFileName = "state.json"

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_003_600)
    private let day: TimeInterval = 24 * 60 * 60

    private var directory: URL!
    private var store: BlocklistStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefreshPolicyTests-\(UUID().uuidString)", isDirectory: true)
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

    private func bytes(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The bytes of the three store files, nil for a missing file.
    private func snapshot() -> [Data?] {
        [
            bytes(BlocklistStore.blocklistFileName),
            bytes(BlocklistStore.callDirectoryFileName),
            bytes(Self.stateFileName),
        ]
    }

    /// Stores the seed at `t0`, with ETag "x" and no recorded success.
    private func acceptSeed() throws {
        XCTAssertEqual(try store.accept(Contract.data(Self.seedFile), etag: "x", now: t0), .accepted)
    }

    // MARK: - AC-6: request

    private let url = URL(string: "https://blocklist.example.invalid/v1/blocklist.json")

    func testRequestWithoutETag() throws {
        let request = RefreshPolicy.request(url: try XCTUnwrap(url), etag: nil)
        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRequestWithETag() throws {
        let request = RefreshPolicy.request(url: try XCTUnwrap(url), etag: "abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "abc")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRequestSendsETagVerbatim() throws {
        let etag = "W/\"5d8c-abc\""
        let request = RefreshPolicy.request(url: try XCTUnwrap(url), etag: etag)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), etag)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
    }

    func testRequestWithEmptyETag() throws {
        let request = RefreshPolicy.request(url: try XCTUnwrap(url), etag: "")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    // MARK: - AC-7: handle

    func testHandle200NewerAccepted() throws {
        try acceptSeed()
        let test = try Contract.data(Self.testFile)

        let outcome = try RefreshPolicy.handle(status: 200, body: test, etag: "\"v2\"", store: store, now: now)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), test)
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.testVersion)
        XCTAssertEqual(state.etag, "\"v2\"")
        XCTAssertEqual(state.lastSuccessAt, now)
        XCTAssertEqual(state.firstRunAt, t0)
    }

    func testHandle200IntoEmptyStore() throws {
        let seed = try Contract.data(Self.seedFile)

        let outcome = try RefreshPolicy.handle(status: 200, body: seed, etag: "e", store: store, now: now)

        XCTAssertEqual(outcome, .accepted)
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.version, Self.seedVersion)
        XCTAssertEqual(state.etag, "e")
        XCTAssertEqual(state.lastSuccessAt, now)
        XCTAssertEqual(state.firstRunAt, now)
    }

    func testHandle200NotNewerRecordsSuccessOnly() throws {
        try acceptSeed()
        let listBefore = bytes(BlocklistStore.blocklistFileName)
        let entriesBefore = bytes(BlocklistStore.callDirectoryFileName)

        let outcome = try RefreshPolicy.handle(
            status: 200, body: try Contract.data(Self.seedFile), etag: "y", store: store, now: now
        )

        XCTAssertEqual(outcome, .ignoredNotNewer)
        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), listBefore)
        XCTAssertEqual(bytes(BlocklistStore.callDirectoryFileName), entriesBefore)
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.lastSuccessAt, now)
        XCTAssertEqual(state.etag, "x", "a not-newer list must not change the ETag")
        XCTAssertEqual(state.version, Self.seedVersion)
    }

    func testHandle200InvalidRejectedNoSuccess() throws {
        try acceptSeed()
        let before = snapshot()

        let outcome = try RefreshPolicy.handle(
            status: 200, body: Data("{not json".utf8), etag: "y", store: store, now: now
        )

        XCTAssertEqual(outcome, .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), before, "a rejected list must not record a success")
        XCTAssertNil(store.state()?.lastSuccessAt)
    }

    func testHandle200MissingBodyRejected() throws {
        try acceptSeed()
        let before = snapshot()

        let outcome = try RefreshPolicy.handle(status: 200, body: nil, etag: nil, store: store, now: now)

        XCTAssertEqual(outcome, .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), before)
    }

    func testHandle304RecordsSuccess() throws {
        try acceptSeed()
        let listBefore = bytes(BlocklistStore.blocklistFileName)
        let entriesBefore = bytes(BlocklistStore.callDirectoryFileName)

        let outcome = try RefreshPolicy.handle(status: 304, body: Data(), etag: "x", store: store, now: now)

        XCTAssertEqual(outcome, .notModified)
        XCTAssertEqual(bytes(BlocklistStore.blocklistFileName), listBefore)
        XCTAssertEqual(bytes(BlocklistStore.callDirectoryFileName), entriesBefore)
        let state = try XCTUnwrap(store.state())
        XCTAssertEqual(state.lastSuccessAt, now)
        XCTAssertEqual(state.etag, "x")
    }

    func testHandle500Failed() throws {
        try acceptSeed()
        let before = snapshot()

        let outcome = try RefreshPolicy.handle(
            status: 500, body: try Contract.data(Self.testFile), etag: "y", store: store, now: now
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(snapshot(), before)
    }

    func testHandleNoResponseFailed() throws {
        try acceptSeed()
        let before = snapshot()

        let outcome = try RefreshPolicy.handle(status: nil, body: nil, etag: nil, store: store, now: now)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(snapshot(), before)
    }

    func testHandleOversizedBodyFailed() throws {
        try acceptSeed()
        let before = snapshot()
        let body = Data(count: RefreshPolicy.maxBodyBytes + 1)

        let outcome = try RefreshPolicy.handle(status: 200, body: body, etag: "y", store: store, now: now)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(snapshot(), before)
    }

    func testMaxBodyBytesIsFiveMiB() {
        XCTAssertEqual(RefreshPolicy.maxBodyBytes, 5_242_880)
    }

    func testHandleBodyAtExactlyTheCapIsNotTooLarge() throws {
        try acceptSeed()
        let before = snapshot()
        let body = Data(count: RefreshPolicy.maxBodyBytes)

        let outcome = try RefreshPolicy.handle(status: 200, body: body, etag: "y", store: store, now: now)

        // Reaches the decoder, which rejects the zero bytes.
        XCTAssertEqual(outcome, .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), before)
    }

    func testHandleOversized304Failed() throws {
        try acceptSeed()
        let before = snapshot()
        let body = Data(count: RefreshPolicy.maxBodyBytes + 1)

        let outcome = try RefreshPolicy.handle(status: 304, body: body, etag: "x", store: store, now: now)

        XCTAssertEqual(outcome, .failed, "the size check comes before the status")
        XCTAssertEqual(snapshot(), before)
    }

    func testHandleOtherStatusesFailed() throws {
        try acceptSeed()
        let before = snapshot()
        let test = try Contract.data(Self.testFile)

        for status in [0, 100, 201, 204, 206, 301, 302, 400, 403, 404, 429, 503] {
            let outcome = try RefreshPolicy.handle(status: status, body: test, etag: "y", store: store, now: now)
            XCTAssertEqual(outcome, .failed, "status \(status)")
            XCTAssertEqual(snapshot(), before, "status \(status)")
        }
    }

    func testHandle304IntoEmptyStoreWritesNothing() throws {
        let outcome = try RefreshPolicy.handle(status: 304, body: nil, etag: "x", store: store, now: now)

        XCTAssertEqual(outcome, .notModified)
        XCTAssertEqual(snapshot(), [nil, nil, nil])
    }

    func testHandle200InvalidIntoEmptyStoreWritesNothing() throws {
        let outcome = try RefreshPolicy.handle(
            status: 200, body: Data("[]".utf8), etag: "y", store: store, now: now
        )

        XCTAssertEqual(outcome, .rejected(.invalid(field: "root")))
        XCTAssertEqual(snapshot(), [nil, nil, nil])
    }

    // MARK: - AC-8: isStale

    func testStalenessRestartsAt304() throws {
        try acceptSeed()
        XCTAssertEqual(
            try RefreshPolicy.handle(status: 304, body: nil, etag: nil, store: store, now: now),
            .notModified
        )
        let state = try XCTUnwrap(store.state())

        // t0 + day + 1 would be stale from firstRunAt, but not from the 304.
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0 + day + 1))
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: now + day))
        XCTAssertTrue(RefreshPolicy.isStale(state: state, now: now + day + 1))
    }

    func testStaleAfter24HoursFromLastSuccess() {
        let state = BlocklistState(
            version: Self.seedVersion,
            entriesVersion: Self.seedVersion,
            lastSuccessAt: t0,
            firstRunAt: t0 - 10 * day
        )
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0))
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0 + day), "exactly 24 hours is not stale")
        XCTAssertTrue(RefreshPolicy.isStale(state: state, now: t0 + day + 1))
    }

    func testFreshOfflineInstallMeasuredFromFirstRun() throws {
        try acceptSeed()
        let state = try XCTUnwrap(store.state())
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertEqual(state.firstRunAt, t0)

        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0))
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0 + day))
        XCTAssertTrue(RefreshPolicy.isStale(state: state, now: t0 + day + 1))
    }

    func testNotStaleWithoutAnyTime() {
        let state = BlocklistState(version: Self.seedVersion, entriesVersion: Self.seedVersion)
        XCTAssertFalse(RefreshPolicy.isStale(state: state, now: t0 + 365 * day))
    }
}
