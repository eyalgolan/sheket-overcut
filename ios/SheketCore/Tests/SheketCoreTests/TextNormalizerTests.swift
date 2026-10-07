import Foundation
import SheketCore
import XCTest

/// Tests for `TextNormalizer`: NFKC, then Hebrew niqqud removal, then
/// lowercasing (spec section 6.1).
final class TextNormalizerTests: XCTestCase {
    /// Compares on Unicode scalars: `String` equality would hide a mark that
    /// was kept or dropped in a canonically equivalent form.
    private func assertNormalizes(
        _ input: String, to expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Array(TextNormalizer.normalize(input).unicodeScalars),
            Array(expected.unicodeScalars),
            "in: \(String(reflecting: input))", file: file, line: line
        )
    }

    /// Wraps one scalar between two Hebrew letters.
    private func between(_ value: UInt32) -> String {
        "א" + String(Unicode.Scalar(value)!) + "ב"
    }

    func testNonspacingMarksInTheHebrewRangeAreRemoved() {
        var removed = 0
        for value in UInt32(0x0591)...0x05C7 {
            let scalar = Unicode.Scalar(value)!
            guard scalar.properties.generalCategory == .nonspacingMark else { continue }
            assertNormalizes(between(value), to: "אב")
            removed += 1
        }
        XCTAssertGreaterThan(removed, 0)
    }

    func testHebrewPunctuationInTheRangeIsKept() {
        // Maqaf, paseq, sof pasuq and nun hafukha are the only scalars in
        // U+0591-U+05C7 that are not Mn; each is kept.
        let kept: [UInt32] = [0x05BE, 0x05C0, 0x05C3, 0x05C6]
        for value in kept {
            assertNormalizes(between(value), to: between(value))
        }
        let notMn = (UInt32(0x0591)...0x05C7).filter {
            Unicode.Scalar($0)!.properties.generalCategory != .nonspacingMark
        }
        XCTAssertEqual(notMn, kept, "the Unicode data has moved; revisit design Open Question 3")
    }

    func testGershayimAndArabicShaddaAreKept() {
        assertNormalizes("ש\u{05F4}ס", to: "ש\u{05F4}ס") // gershayim
        assertNormalizes("صوّتوا", to: "صوّتوا") // shadda U+0651
        assertNormalizes("\u{0651}", to: "\u{0651}")
    }

    func testPointedHebrewLosesItsNiqqud() {
        assertNormalizes("בְּחִירוֹת", to: "בחירות")
        assertNormalizes("הוֹדָעַת בְּחִירוֹת", to: "הודעת בחירות")
    }

    func testNFKCRunsBeforeNiqqudRemoval() {
        // U+FB2A (shin with shin dot) decomposes under NFKC to U+05E9 U+05C1;
        // the dot is only removed if NFKC runs first.
        assertNormalizes("\u{FB2A}", to: "ש")
        // U+FB2E (alef with patah) gives U+05D0 U+05B7.
        assertNormalizes("\u{FB2E}", to: "א")
    }

    func testNFKCCompatibilityForms() {
        assertNormalizes("ＡＢＣ１２３", to: "abc123") // fullwidth
        assertNormalizes("\u{FB01}", to: "fi") // ligature
        assertNormalizes("e\u{0301}", to: "\u{00E9}") // composed
    }

    func testLowercasing() {
        assertNormalizes("ГОЛОСУЙТЕ ЗА", to: "голосуйте за")
        assertNormalizes("Vote NOW", to: "vote now")
    }

    func testEmptyStaysEmpty() {
        assertNormalizes("", to: "")
    }

    func testNormalizeIsIdempotent() {
        for s in ["בְּחִירוֹת", "ГОЛОСУЙТЕ ЗА", "\u{FB2A}", "صوّتوا للقائمة", "ＡＢＣ"] {
            let once = TextNormalizer.normalize(s)
            assertNormalizes(once, to: once)
        }
    }

    // MARK: - Contract lists (AC-8)

    func testContractKeywordsAreUnchangedByNormalisation() throws {
        for file in Contract.blocklistFiles.values.sorted() {
            let list = try Contract.blocklist(file)
            XCTAssertFalse(list.smsKeywords.isEmpty, "\(file) has no sms_keywords")
            for keyword in list.smsKeywords {
                XCTAssertEqual(
                    Array(TextNormalizer.normalize(keyword.text).unicodeScalars),
                    Array(keyword.text.unicodeScalars),
                    "\(file): \(String(reflecting: keyword.text))"
                )
            }
        }
    }
}
