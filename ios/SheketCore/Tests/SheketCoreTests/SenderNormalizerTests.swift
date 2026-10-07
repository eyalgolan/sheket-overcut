import Foundation
import SheketCore
import XCTest

/// Edge cases for `SenderNormalizer` beyond the corpus, ported from
/// `backend/tests/test_normalize_rules.py`. Expected values were checked
/// against the backend's `normalize_sender`.
final class SenderNormalizerTests: XCTestCase {
    // MARK: - Helpers

    /// Compares on Unicode scalars, as the backend compares code points.
    private func assertNormalizes(
        _ raw: String, to expected: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            SenderNormalizer.normalize(raw).map { Array($0.unicodeScalars) },
            expected.map { Array($0.unicodeScalars) },
            "in: \(String(reflecting: raw))", file: file, line: line
        )
    }

    /// `^\+[1-9][0-9]{6,14}$`, checked independently of `isE164` with a
    /// whole-string Swift `Regex` (which, unlike an ICU `$`, does not accept
    /// a trailing newline).
    private func matchesE164Pattern(_ s: String) throws -> Bool {
        try Regex(#"\+[1-9][0-9]{6,14}"#).wholeMatch(in: s) != nil
    }

    // MARK: - isE164

    func testIsE164Accepts() {
        for s in ["+972555001234", "+12125550100", "+1234567", "+123456789012345"] {
            XCTAssertTrue(SenderNormalizer.isE164(s), String(reflecting: s))
        }
    }

    func testIsE164Rejects() {
        let rejected = [
            "",
            "+",
            "972555001234", // no leading +
            "+0972555001234", // leading zero after +
            "+123456", // 6 digits: too short
            "+1234567890123456", // 16 digits: too long
            "+972 55 500 1234", // separators are not stripped
            "+972555001234\n", // trailing newline must not slip past $
            " +972555001234",
            "+٩٧٢٥٥٥٠٠١٢٣٤", // Arabic-Indic digits are not [0-9]
            "+９７２５５５００１２３４", // fullwidth digits are not [0-9]
            "*2700",
            "100",
        ]
        for s in rejected {
            XCTAssertFalse(SenderNormalizer.isE164(s), String(reflecting: s))
        }
    }

    // MARK: - Input that is not a sender

    func testWhitespaceOnlyReturnsNil() {
        for raw in ["", "\t", "\n", " \t\r\n ", "\u{3000}", "\u{A0}", "\u{1C}\u{1D}\u{1E}\u{1F}"] {
            assertNormalizes(raw, to: nil)
        }
    }

    func testPhoneShapedJunkWithoutDigitsReturnsNil() {
        for raw in ["-", "+", "()", "( )", "- -", "+()-"] {
            assertNormalizes(raw, to: nil)
        }
    }

    // MARK: - Trimming (Python str.strip())

    func testInformationSeparatorsAreTrimmed() {
        // U+001C-001F are str.isspace() but not in .whitespacesAndNewlines.
        assertNormalizes("\u{1C}100\u{1C}", to: "100")
        assertNormalizes("\u{1D}\u{1E}\u{1F}0555001234\u{1F}", to: "+972555001234")
    }

    func testEveryPythonWhitespaceScalarIsTrimmed() {
        let pythonWhitespace: [UInt32] = Array(0x09...0x0D) + Array(0x1C...0x20)
            + [0x85, 0xA0, 0x1680] + Array(0x2000...0x200A)
            + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        for value in pythonWhitespace {
            let space = String(Unicode.Scalar(value)!)
            assertNormalizes(space + "100" + space, to: "100")
            assertNormalizes(space + "Leumi" + space, to: "leumi")
        }
    }

    func testNonWhitespaceFormatScalarsAreNotTrimmed() {
        // U+200B is not str.isspace(): the input is a sender ID, kept whole.
        assertNormalizes("\u{200B}100", to: "\u{200B}100")
    }

    func testTrimmingWorksOnScalarsNotCharacters() {
        // A space followed by a combining mark is one Character, but
        // str.strip() still removes the space.
        assertNormalizes(" \u{0301}abc", to: "\u{0301}abc")
    }

    // MARK: - Phone numbers

    func testSpellingsOfOneIsraeliMobileNumberConverge() {
        let spellings = [
            "055-500-1234",
            "0555001234",
            "972555001234",
            "+972555001234",
            "+972 55 500 1234",
            "+972-55-500-1234",
            "(055) 500-1234",
            "+972 (55) 500-1234",
            "\t055 500 1234\n",
        ]
        for raw in spellings {
            assertNormalizes(raw, to: "+972555001234")
        }
    }

    func testPhoneRules() {
        assertNormalizes("03-555-0123", to: "+97235550123") // 0 + 8 digits (landline)
        assertNormalizes("035550123", to: "+97235550123")
        assertNormalizes("97235550123", to: "+97235550123") // 972 + 8 digits
        assertNormalizes("+1 212 555 0100", to: "+12125550100") // foreign, kept as written
        assertNormalizes("+44 20 7946 0000", to: "+442079460000")
    }

    func testPlusNumbersAreKeptAsWritten() {
        // "(0)" is not special-cased for any country.
        assertNormalizes("+9720555001234", to: "+9720555001234")
        assertNormalizes("+972 (0)55 500 1234", to: "+9720555001234")
        assertNormalizes("+44 (0)20 7946 0000", to: "+4402079460000")
    }

    func testUnplaceableNumbersReturnNil() {
        let unplaceable = [
            "05550012345", // 0 + 10 digits: too long for a national number
            "0555001", // 0 + 6 digits: too short
            "9725550012345", // 972 + 10 digits
            "12125550100", // no +, not Israeli: country unknown
            "123456", // 6 digits: not a short service number
            "99", // 2 digits: too short for a short service number
            "012", // short number may not start with 0
            "+0555001234", // + then 0 is never E.164
            "+123456", // + then 6 digits: too short for E.164
            "+1234567890123456", // + then 16 digits: too long for E.164
            "0055001234", // 00 is the international prefix
            "00972555001234",
            "001234567",
            "9720555001234", // 972 + 10 digits
            "1800500500", // Israeli 1-800 number: no trunk 0
            "1-800-500-500",
            "1700500500",
        ]
        for raw in unplaceable {
            assertNormalizes(raw, to: nil)
        }
    }

    func testShortServiceNumbersStayAsWritten() {
        for raw in ["100", "101", "112", "1201", "12345"] {
            assertNormalizes(raw, to: raw)
        }
        assertNormalizes("  112 ", to: "112")
    }

    func testShortServiceNumberSeparatorsAreRemoved() {
        assertNormalizes("1-0-0", to: "100")
        assertNormalizes("(1) 0 1", to: "101")
    }

    func testPhoneOutputsAlwaysMatchTheE164Pattern() throws {
        let inputs = [
            "055-500-1234", "0555001234", "972555001234", "+972555001234",
            "+972 55 500 1234", "(055) 500-1234", "03-555-0123", "97235550123",
            "+1 212 555 0100", "+44 20 7946 0000", "+9720555001234",
            "+972 (0)55 500 1234", "+44 (0)20 7946 0000", "\u{1C}0555001234\u{1C}",
        ]
        for raw in inputs {
            let out = SenderNormalizer.normalize(raw)
            XCTAssertNotNil(out, "in: \(String(reflecting: raw))")
            guard let out else { continue }
            XCTAssertTrue(try matchesE164Pattern(out), "in: \(String(reflecting: raw)), out: \(out)")
            XCTAssertTrue(SenderNormalizer.isE164(out), "in: \(String(reflecting: raw)), out: \(out)")
            XCTAssertEqual(SenderNormalizer.normalize(out), out, "not stable: \(String(reflecting: raw))")
        }
    }

    // MARK: - Star codes

    func testStarCodesStayAsWritten() {
        for raw in ["*2700", "*507", "*3857", "*12", "*123456"] {
            assertNormalizes(raw, to: raw)
        }
        assertNormalizes("  *2700  ", to: "*2700")
    }

    // MARK: - Sender IDs

    func testSenderIDsAreTrimmedAndCaseFolded() {
        assertNormalizes("ExampleParty", to: "exampleparty")
        assertNormalizes("  Leumi  ", to: "leumi")
        assertNormalizes("MACCABI", to: "maccabi")
        assertNormalizes("gov.il", to: "gov.il")
        assertNormalizes("Bank-Hapoalim", to: "bank-hapoalim")
        assertNormalizes("a", to: "a")
        assertNormalizes("G-482913", to: "g-482913")
        assertNormalizes("Bank1", to: "bank1")
    }

    func testSenderIDLengthLimit() {
        assertNormalizes(String(repeating: "A", count: 20), to: String(repeating: "a", count: 20))
        assertNormalizes(String(repeating: "A", count: 21), to: nil)
        // Surrounding whitespace does not count.
        assertNormalizes("   " + String(repeating: "A", count: 20) + "   ", to: String(repeating: "a", count: 20))
    }

    /// Port of `test_sender_id_length_is_measured_after_casefold`.
    func testSenderIDLengthIsMeasuredAfterCaseFold() {
        // "ß" case-folds to "ss": 11 characters in, 22 after case-folding.
        assertNormalizes(String(repeating: "ß", count: 10), to: String(repeating: "ss", count: 10))
        assertNormalizes(String(repeating: "ß", count: 11), to: nil)
    }

    func testSenderIDsWithInternalWhitespaceReturnNil() {
        let inputs = [
            "Example Party",
            "Example\tParty",
            "Example\nParty",
            "Example\u{A0}Party",
            "Example\u{1C}Party",
            "Example\u{3000}Party",
            "this is a sentence, not a sender",
        ]
        for raw in inputs {
            assertNormalizes(raw, to: nil)
        }
    }

    func testNumberShapedInputOutsideThePhoneRulesIsASenderID() {
        // None of these has a letter, so case-folding leaves them unchanged.
        let inputs = [
            "٠٥٥٥٠٠١٢٣٤", // Arabic-Indic digits are not [0-9]
            "+٩٧٢٥٥٥٠٠١٢٣٤",
            "０５５５００１２３４", // fullwidth digits
            "055.500.1234",
            "+972.55.500.1234",
            "055/500/1234",
            "++972555001234",
            "*",
            "*1",
            "*1234567",
            "*١٢٣٤",
        ]
        for raw in inputs {
            assertNormalizes(raw, to: raw)
        }
    }

    func testNormalizeIsIdempotent() {
        for raw in ["0555001234", "+972 55 500 1234", "ExampleParty", "*2700", "100", "gov.il",
                    "٠٥٥٥٠٠١٢٣٤", String(repeating: "ß", count: 10)] {
            let once = SenderNormalizer.normalize(raw)
            XCTAssertNotNil(once, "in: \(String(reflecting: raw))")
            if let once {
                assertNormalizes(once, to: once)
            }
        }
    }

    // MARK: - Contract lists (AC-8)

    func testSeedListSendersAreFixedPoints() throws {
        let seed = try Contract.blocklist("seed-blocklist.json")
        XCTAssertFalse(seed.smsAllowSenders.isEmpty, "seed list has no sms_allow_senders")
        for sender in seed.smsAllowSenders + seed.smsSenders {
            assertNormalizes(sender, to: sender)
        }
    }

    func testTestListSendersNormaliseToFixedPoints() throws {
        let list = try Contract.blocklist("test-blocklist.json")
        let senders = list.smsSenders + list.smsAllowSenders
        XCTAssertFalse(senders.isEmpty)
        for sender in senders {
            let once = SenderNormalizer.normalize(sender)
            XCTAssertNotNil(once, String(reflecting: sender))
            guard let once else { continue }
            assertNormalizes(once, to: once)
            if SenderNormalizer.isE164(sender) {
                // A listed number never turns into a different number.
                XCTAssertEqual(once, sender)
            }
        }
        for number in list.callNumbers {
            assertNormalizes(number, to: number)
        }
    }
}
