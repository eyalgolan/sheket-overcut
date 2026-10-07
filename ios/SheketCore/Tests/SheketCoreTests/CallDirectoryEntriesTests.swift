import Foundation
import SheketCore
import XCTest

/// Tests for `CallDirectoryEntries` (spec sections 4 and 6.1): prefix
/// expansion, the exact 500,000-entry cap, the stored format and lookup.
final class CallDirectoryEntriesTests: XCTestCase {
    // MARK: - Helpers

    /// A blocklist with only call numbers and prefixes set.
    private func list(numbers: [String] = [], prefixes: [String] = []) -> Blocklist {
        Blocklist(
            version: 1,
            generatedAt: "2026-10-05T12:00:00Z",
            callNumbers: numbers,
            callPrefixes: prefixes,
            smsSenders: [],
            smsKeywords: [],
            smsAllowSenders: []
        )
    }

    /// 51 prefixes with 4 free digits each, "+97255100" to "+97255150".
    /// The first 50 fill the 500,000 cap exactly.
    private let fiftyOnePrefixes = (0..<51).map { "+97255\(100 + $0)" }

    // MARK: - Cap (only two 500,000-entry builds, to keep the run short)

    func testCapAtExactly500000() {
        let entries = CallDirectoryEntries.build(list(prefixes: fiftyOnePrefixes))

        XCTAssertEqual(entries.count, 500_000)
        XCTAssertEqual(entries.count, CallDirectoryEntries.defaultCap)
        XCTAssertEqual(entries.last, 972_551_499_999, "last entry must end the 50th prefix, +97255149")
        XCTAssertFalse(entries.contains { $0 >= 972_551_500_000 }, "the 51st prefix, +97255150, must add nothing")
    }

    func testCapStopsPartWayThroughAPrefix() {
        let entries = CallDirectoryEntries.build(
            list(numbers: ["+972541234567"], prefixes: fiftyOnePrefixes)
        )

        XCTAssertEqual(entries.count, 500_000)
        XCTAssertTrue(entries.contains(972_541_234_567))
        // The number takes one slot, so +97255149 adds only 9,999 entries.
        XCTAssertEqual(entries.filter { (972_551_490_000...972_551_499_999).contains($0) }.count, 9_999)
        XCTAssertFalse(entries.contains(972_551_499_999))
        XCTAssertTrue(entries.contains(972_551_499_998))
    }

    func testCapFilledByCallNumbersFirst() {
        let entries = CallDirectoryEntries.build(
            list(
                numbers: ["+972555000005", "+972555000001", "+972555000001", "+972555000003", "+972555000004"],
                prefixes: ["+97255501"]
            ),
            cap: 3
        )

        // The first three distinct numbers in document order, sorted; the
        // duplicate does not use up the cap and the prefix adds nothing.
        XCTAssertEqual(entries, [972_555_000_001, 972_555_000_003, 972_555_000_005])
    }

    // MARK: - Expansion

    func testOverlapsCountedOnce() {
        XCTAssertEqual(
            CallDirectoryEntries.build(list(numbers: ["+972555011234"], prefixes: ["+97255501"])).count,
            10_000, "a number inside a prefix"
        )
        XCTAssertEqual(
            CallDirectoryEntries.build(list(prefixes: ["+97255501", "+972555012"])).count,
            10_000, "a prefix inside a prefix"
        )
        XCTAssertEqual(
            CallDirectoryEntries.build(list(prefixes: ["+97255501", "+97255501"])).count,
            10_000, "a repeated prefix"
        )
    }

    func testPrefixesOutsideZeroToFourFreeDigitsAreSkipped() {
        for prefix in ["+1212", "+9725552", "+9725550123456"] {
            XCTAssertEqual(CallDirectoryEntries.build(list(prefixes: [prefix])), [],
                           "prefix \(prefix) must be skipped")
        }

        XCTAssertEqual(CallDirectoryEntries.build(list(prefixes: ["+972555012345"])), [972_555_012_345])

        let threeFree = CallDirectoryEntries.build(list(prefixes: ["+972555012"]))
        XCTAssertEqual(threeFree.count, 1_000)
        XCTAssertEqual(threeFree.first, 972_555_012_000)
        XCTAssertEqual(threeFree.last, 972_555_012_999)
    }

    // MARK: - Stored format

    func testRoundTrip() throws {
        let built = CallDirectoryEntries.build(try Contract.blocklist("test-blocklist.json"))
        for input in [built, [1, 2, Int64.max]] {
            var read: [Int64] = []
            try CallDirectoryEntries.forEachEntry(in: CallDirectoryEntries.encode(input)) { read.append($0) }
            XCTAssertEqual(read, input)
        }

        var calls = 0
        try CallDirectoryEntries.forEachEntry(in: CallDirectoryEntries.encode([])) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }

    func testEncodeIsLittleEndian() {
        XCTAssertEqual(CallDirectoryEntries.encode([1]), Data([1, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testUnalignedSlice() throws {
        var data = Data([0xFF])
        data.append(CallDirectoryEntries.encode([5, 7]))
        let slice = data.dropFirst()

        var read: [Int64] = []
        try CallDirectoryEntries.forEachEntry(in: slice) { read.append($0) }
        XCTAssertEqual(read, [5, 7])
    }

    func testCorrupt() {
        let cases: [(String, Data)] = [
            ("7 bytes", Data(count: 7)),
            ("9 bytes", CallDirectoryEntries.encode([1]) + Data([0])),
            ("out of order", CallDirectoryEntries.encode([2, 1])),
            ("duplicate", CallDirectoryEntries.encode([3, 3])),
            ("zero", CallDirectoryEntries.encode([0])),
            ("negative", CallDirectoryEntries.encode([-5])),
            ("negative after positive", CallDirectoryEntries.encode([1, -1])),
        ]
        for (label, data) in cases {
            XCTAssertThrowsError(try CallDirectoryEntries.forEachEntry(in: data, { _ in }), label) { error in
                XCTAssertEqual(error as? CallDirectoryEntriesError, .corrupt, "\(label): \(error)")
            }
        }
    }

    // MARK: - Lookup

    func testNotBlocked() throws {
        let entries = CallDirectoryEntries.build(try Contract.blocklist("test-blocklist.json"))
        for raw in ["", "Unknown", "100", "*2700"] {
            XCTAssertFalse(CallDirectoryEntries.isBlocked(raw, entries: entries), String(reflecting: raw))
        }

        // Short numbers and star codes are never E.164, even if their digits
        // were somehow in the entries.
        XCTAssertFalse(CallDirectoryEntries.isBlocked("100", entries: [100, 2700]))
        XCTAssertFalse(CallDirectoryEntries.isBlocked("*2700", entries: [100, 2700]))

        XCTAssertTrue(CallDirectoryEntries.isBlocked("+972555001234", entries: entries))
    }
}
