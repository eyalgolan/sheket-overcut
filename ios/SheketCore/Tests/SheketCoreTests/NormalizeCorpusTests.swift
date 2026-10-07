import Foundation
import SheketCore
import XCTest

/// Runs every `normalize` case in `contract/corpus.json` against
/// `SenderNormalizer.normalize` (spec section 11).
final class NormalizeCorpusTests: XCTestCase {
    func testNormalizeCorpus() throws {
        let cases = try Contract.corpusSection("normalize")
        // An empty section would pass silently instead of testing anything.
        XCTAssertFalse(cases.isEmpty, "contract/corpus.json has no normalize cases")

        for (index, testCase) in cases.enumerated() {
            guard let input = testCase["in"] as? String else {
                XCTFail("normalize case \(index): \"in\" is not a string: \(testCase)")
                continue
            }
            let label = "normalize case \(index), in: \(String(reflecting: input))"
            let expected: String?
            switch testCase["out"] {
            case is NSNull:
                expected = nil
            case let out as String:
                expected = out
            default:
                XCTFail("\(label): \"out\" is neither a string nor null")
                continue
            }
            XCTAssertEqual(
                SenderNormalizer.normalize(input).map { Array($0.unicodeScalars) },
                expected.map { Array($0.unicodeScalars) },
                label
            )
        }
    }

    /// Every phone-number `out` passes `isE164`.
    func testNormalizeCorpusPhoneOutputsAreE164() throws {
        let phones = try Contract.corpusSection("normalize")
            .compactMap { $0["out"] as? String }
            .filter { $0.hasPrefix("+") }
        XCTAssertFalse(phones.isEmpty, "contract/corpus.json has no phone normalize outputs")
        for out in phones {
            XCTAssertTrue(SenderNormalizer.isE164(out), out)
        }
    }

    /// Every non-null `out` is already normalised, so normalising it again
    /// changes nothing.
    func testNormalizeCorpusOutputsAreFixedPoints() throws {
        let cases = try Contract.corpusSection("normalize")
        XCTAssertFalse(cases.isEmpty, "contract/corpus.json has no normalize cases")
        for testCase in cases {
            guard let out = testCase["out"] as? String else { continue }
            XCTAssertEqual(SenderNormalizer.normalize(out), out,
                           "in: \(String(reflecting: testCase["in"] as? String))")
        }
    }
}
