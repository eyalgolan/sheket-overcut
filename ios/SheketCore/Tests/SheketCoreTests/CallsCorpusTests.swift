import Foundation
import SheketCore
import XCTest

/// Runs `contract/test-blocklist.json` and every `calls` case in
/// `contract/corpus.json` through `CallDirectoryEntries` (spec sections 4,
/// 6.1 and 11), so the tests check exactly the entries iOS installs.
final class CallsCorpusTests: XCTestCase {
    func testTestBlocklistBuildsTo10002Entries() throws {
        let entries = CallDirectoryEntries.build(try Contract.blocklist("test-blocklist.json"))

        // The only hard-coded count: contract/README.md "`test-blocklist.json`"
        // gives 2 call numbers plus 10,000 entries from +97255501, with
        // +9725552 skipped.
        XCTAssertEqual(entries.count, 10_002)
        XCTAssertTrue(zip(entries, entries.dropFirst()).allSatisfy { $0 < $1 },
                      "entries are not strictly ascending")
        XCTAssertEqual(entries.filter { (972_555_010_000...972_555_019_999).contains($0) }.count, 10_000,
                       "+97255501 (4 free digits) must expand to 10,000 entries")
        XCTAssertFalse(entries.contains { (972_555_200_000...972_555_299_999).contains($0) },
                       "+9725552 (5 free digits) must be skipped")
        XCTAssertTrue(entries.contains(972_555_001_234))
        XCTAssertTrue(entries.contains(972_555_009_876))
    }

    func testCallsCorpus() throws {
        let cases = try Contract.corpusSection("calls")
        // An empty section would pass silently instead of testing anything.
        XCTAssertFalse(cases.isEmpty, "contract/corpus.json has no calls cases")

        let entries = CallDirectoryEntries.build(try Contract.blocklist("test-blocklist.json"))

        for (index, testCase) in cases.enumerated() {
            let why = testCase["why"] as? String ?? "<no why>"
            let label = "calls case \(index), why: \(why)"
            guard let number = testCase["number"] as? String else {
                XCTFail("\(label): \"number\" is not a string")
                continue
            }
            let expected: Bool
            switch testCase["expect"] as? String {
            case "block":
                expected = true
            case "allow":
                expected = false
            default:
                XCTFail("\(label): unknown expect \(String(describing: testCase["expect"]))")
                continue
            }
            XCTAssertEqual(
                CallDirectoryEntries.isBlocked(number, entries: entries),
                expected,
                "\(label); number: \(String(reflecting: number))"
            )
        }
    }
}
