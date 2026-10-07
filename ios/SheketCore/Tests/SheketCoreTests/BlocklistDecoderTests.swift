import Foundation
import SheketCore
import XCTest

/// Tests for the strict `BlocklistDecoder` (spec sections 6.1 and 7,
/// `contract/blocklist.schema.json`). Each rejection is made by changing
/// `contract/test-blocklist.json` in memory; the file is never written.
final class BlocklistDecoderTests: XCTestCase {
    // MARK: - Helpers

    private func testListText() throws -> String {
        try XCTUnwrap(String(data: Contract.data("test-blocklist.json"), encoding: .utf8))
    }

    private func testListObject() throws -> [String: Any] {
        try Contract.object("test-blocklist.json")
    }

    /// Decodes the test list after one textual replacement. Used for number
    /// spellings (`1.0`, `true`, huge integers) that must reach the decoder
    /// exactly as written, which re-serialising an object would not ensure.
    private func decodeReplacing(_ target: String, with replacement: String) throws -> Blocklist {
        let text = try testListText()
        let parts = text.components(separatedBy: target)
        XCTAssertEqual(parts.count, 2, "expected exactly one \(String(reflecting: target)) in test-blocklist.json")
        return try BlocklistDecoder.decode(Data(parts.joined(separator: replacement).utf8))
    }

    /// Decodes the test list after changing its parsed object.
    private func decodeChanging(_ change: (inout [String: Any]) throws -> Void) throws -> Blocklist {
        var root = try testListObject()
        try change(&root)
        return try BlocklistDecoder.decode(JSONSerialization.data(withJSONObject: root))
    }

    /// Decodes the test list with `key` set to `value`.
    private func decodeSetting(_ key: String, to value: Any) throws -> Blocklist {
        try decodeChanging { $0[key] = value }
    }

    /// Decodes the test list with the first keyword object changed.
    private func decodeChangingFirstKeyword(_ change: (inout [String: Any]) -> Void) throws -> Blocklist {
        try decodeChanging { root in
            var keywords = try XCTUnwrap(root["sms_keywords"] as? [[String: Any]])
            XCTAssertFalse(keywords.isEmpty)
            change(&keywords[0])
            root["sms_keywords"] = keywords
        }
    }

    private func assertRejected(
        _ field: String,
        _ label: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ decode: () throws -> Blocklist
    ) {
        XCTAssertThrowsError(try decode(), label(), file: file, line: line) { error in
            XCTAssertEqual(error as? BlocklistError, .invalid(field: field),
                           "\(label()): \(error)", file: file, line: line)
        }
    }

    // MARK: - Contract lists decode

    func testBothContractListsDecode() throws {
        for file in Contract.blocklistFiles.values.sorted() {
            let list = try Contract.blocklist(file)
            let root = try Contract.object(file)
            XCTAssertEqual(list.version, (root["version"] as? NSNumber)?.int64Value, file)
            XCTAssertEqual(list.generatedAt, root["generated_at"] as? String, file)
            XCTAssertEqual(list.callNumbers, root["call_numbers"] as? [String], file)
            XCTAssertEqual(list.callPrefixes, root["call_prefixes"] as? [String], file)
            XCTAssertEqual(list.smsSenders, root["sms_senders"] as? [String], file)
            XCTAssertEqual(list.smsAllowSenders, root["sms_allow_senders"] as? [String], file)
            let keywords = try XCTUnwrap(root["sms_keywords"] as? [[String: String]], file)
            XCTAssertEqual(list.smsKeywords.map(\.text), keywords.map { $0["text"] ?? "" }, file)
            XCTAssertEqual(list.smsKeywords.map(\.strength.rawValue), keywords.map { $0["strength"] ?? "" }, file)
        }
    }

    func testTheUnchangedTestListRoundTrips() throws {
        // Guards the helpers: with no real change, both decode paths succeed.
        XCTAssertNoThrow(try decodeChanging { _ in })
        XCTAssertNoThrow(try decodeReplacing("\"schema\": 1,", with: "\"schema\": 1,"))
    }

    /// The scans in the decoder port the schema's patterns; pin them so a
    /// `contract:` change to a pattern fails here rather than drifting.
    func testSchemaPatternsAreTheOnesTheDecoderPorts() throws {
        let schema = try Contract.object("blocklist.schema.json")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        func pattern(_ key: String) throws -> String? {
            let property = try XCTUnwrap(properties[key] as? [String: Any])
            let items = try XCTUnwrap(property["items"] as? [String: Any])
            return items["pattern"] as? String
        }
        XCTAssertEqual(try pattern("call_numbers"), #"^\+[1-9][0-9]{6,14}$"#)
        XCTAssertEqual(try pattern("call_prefixes"), #"^\+[1-9][0-9]{3,13}$"#)
    }

    // MARK: - Root and keys

    func testNonObjectRootIsRejected() {
        for json in ["[]", "\"blocklist\"", "1", "null", "true", "", "{", "not json"] {
            assertRejected("root", json) { try BlocklistDecoder.decode(Data(json.utf8)) }
        }
    }

    func testEachMissingRequiredKeyIsRejected() throws {
        let schema = try Contract.object("blocklist.schema.json")
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertFalse(required.isEmpty)
        for key in required {
            assertRejected(key, "without \(key)") { try decodeChanging { $0[key] = nil } }
        }
    }

    func testExtraTopLevelKeyIsRejected() {
        assertRejected("root") { try decodeSetting("extra", to: "value") }
        assertRejected("root") { try decodeSetting("Schema", to: 1) }
    }

    func testExtraKeyInsideAKeywordIsRejected() {
        assertRejected("sms_keywords") { try decodeChangingFirstKeyword { $0["extra"] = "value" } }
    }

    func testMissingKeyInsideAKeywordIsRejected() {
        assertRejected("sms_keywords") { try decodeChangingFirstKeyword { $0["strength"] = nil } }
        assertRejected("sms_keywords") { try decodeChangingFirstKeyword { $0["text"] = nil } }
    }

    func testKeywordThatIsNotAnObjectIsRejected() {
        assertRejected("sms_keywords") { try decodeSetting("sms_keywords", to: ["בחירות"]) }
        assertRejected("sms_keywords") { try decodeSetting("sms_keywords", to: "בחירות") }
    }

    // MARK: - schema and version

    func testSchemaOtherThanOneIsRejected() {
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": 2,") }
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": 0,") }
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": -1,") }
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": \"1\",") }
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": null,") }
    }

    func testBooleanSchemaOrVersionIsRejected() {
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": true,") }
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": false,") }
        let version = "\"version\": 1791201600,"
        assertRejected("version") { try decodeReplacing(version, with: "\"version\": true,") }
        assertRejected("version") { try decodeReplacing(version, with: "\"version\": false,") }
    }

    func testFractionalSchemaOrVersionIsRejected() {
        assertRejected("schema") { try decodeReplacing("\"schema\": 1,", with: "\"schema\": 1.0,") }
        let version = "\"version\": 1791201600,"
        for spelling in ["1.0", "1791201600.0", "1791201600.5", "1.7912016e9"] {
            assertRejected("version", spelling) {
                try decodeReplacing(version, with: "\"version\": \(spelling),")
            }
        }
    }

    func testVersionTooLargeForInt64IsRejected() {
        let version = "\"version\": 1791201600,"
        for spelling in ["9223372036854775808", "18446744073709551615", "99999999999999999999",
                         "-9223372036854775809"] {
            assertRejected("version", spelling) {
                try decodeReplacing(version, with: "\"version\": \(spelling),")
            }
        }
    }

    func testVersionAtTheInt64LimitsIsAccepted() throws {
        let version = "\"version\": 1791201600,"
        XCTAssertEqual(try decodeReplacing(version, with: "\"version\": 9223372036854775807,").version,
                       Int64.max)
        XCTAssertEqual(try decodeReplacing(version, with: "\"version\": 0,").version, 0)
        XCTAssertEqual(try decodeReplacing(version, with: "\"version\": -1,").version, -1)
    }

    func testStringVersionIsRejected() {
        assertRejected("version") { try decodeSetting("version", to: "1791201600") }
    }

    // MARK: - generated_at

    func testGeneratedAtThatIsNotRFC3339IsRejected() {
        let invalid = [
            "",
            "yesterday",
            "2026-10-05",
            "2026-10-05T12:00:00", // no offset
            "2026-10-05 12:00:00Z", // space instead of T
            "2026-10-05T12:00:00+0300", // offset without colon
            "2026-1-05T12:00:00Z",
            "2026-10-05T12:00:00.Z", // empty fraction
            "2026-10-05T12:00:00Z\n", // trailing newline
            " 2026-10-05T12:00:00Z",
            "２０２６-10-05T12:00:00Z", // fullwidth digits
        ]
        for value in invalid {
            assertRejected("generated_at", String(reflecting: value)) {
                try decodeSetting("generated_at", to: value)
            }
        }
        assertRejected("generated_at") { try decodeSetting("generated_at", to: 1791201600) }
    }

    func testImpossibleGeneratedAtIsRejected() {
        let impossible = [
            "2026-02-30T12:00:00Z",
            "2025-02-29T00:00:00Z", // not a leap year
            "1900-02-29T00:00:00Z", // century, not a leap year
            "2026-04-31T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-00-10T00:00:00Z",
            "2026-10-00T00:00:00Z",
            "2026-10-05T24:00:00Z",
            "2026-10-05T12:60:00Z",
            "2026-10-05T12:00:60Z",
            "2026-10-05T12:00:00+24:00",
            "2026-10-05T12:00:00+03:60",
        ]
        for value in impossible {
            assertRejected("generated_at", value) { try decodeSetting("generated_at", to: value) }
        }
    }

    func testValidGeneratedAtFormsAreAccepted() throws {
        let valid = [
            "2026-10-05T12:00:00Z",
            "2026-10-05T12:00:00.123+03:00",
            "2026-10-05T12:00:00-00:00",
            "2024-02-29T00:00:00Z",
            "2000-02-29T23:59:59Z",
        ]
        for value in valid {
            XCTAssertEqual(try decodeSetting("generated_at", to: value).generatedAt, value)
        }
    }

    // MARK: - Call numbers and prefixes

    func testCallNumberThatFailsItsPatternIsRejected() {
        let invalid = ["972555001234", "+0555001234", "+123456", "+1234567890123456",
                       "+972 55 500 1234", "+972555001234\n", "+٩٧٢٥٥٥٠٠١٢٣٤", ""]
        for value in invalid {
            assertRejected("call_numbers", String(reflecting: value)) {
                try decodeSetting("call_numbers", to: ["+972555001234", value])
            }
        }
        assertRejected("call_numbers") { try decodeSetting("call_numbers", to: [972555001234]) }
        assertRejected("call_numbers") { try decodeSetting("call_numbers", to: "+972555001234") }
    }

    func testCallPrefixThatFailsItsPatternIsRejected() {
        let invalid = ["+972", "97255501", "+0255501", "+123456789012345", "+97255501\n",
                       "+972-55501", "+٩٧٢٥", "+", ""]
        for value in invalid {
            assertRejected("call_prefixes", String(reflecting: value)) {
                try decodeSetting("call_prefixes", to: ["+97255501", value])
            }
        }
        assertRejected("call_prefixes") { try decodeSetting("call_prefixes", to: [97255501]) }
    }

    func testCallPrefixBoundariesAreAccepted() throws {
        // [1-9] then 3 to 13 digits.
        let list = try decodeSetting("call_prefixes", to: ["+9725", "+12345678901234"])
        XCTAssertEqual(list.callPrefixes, ["+9725", "+12345678901234"])
    }

    // MARK: - Senders

    func testEmptySenderIsRejected() {
        assertRejected("sms_senders") { try decodeSetting("sms_senders", to: ["ExampleList", ""]) }
        assertRejected("sms_allow_senders") { try decodeSetting("sms_allow_senders", to: [""]) }
    }

    func testNonStringSenderIsRejected() {
        assertRejected("sms_senders") { try decodeSetting("sms_senders", to: [972555004321]) }
        assertRejected("sms_allow_senders") { try decodeSetting("sms_allow_senders", to: [NSNull()]) }
        assertRejected("sms_senders") { try decodeSetting("sms_senders", to: "ExampleList") }
    }

    func testSendersAreStoredAsWritten() throws {
        let list = try decodeSetting("sms_senders", to: ["  Example List  "])
        XCTAssertEqual(list.smsSenders, ["  Example List  "])
    }

    // MARK: - Keywords

    func testEmptyKeywordTextIsRejected() {
        assertRejected("sms_keywords.text") { try decodeChangingFirstKeyword { $0["text"] = "" } }
        assertRejected("sms_keywords.text") { try decodeChangingFirstKeyword { $0["text"] = 1 } }
    }

    func testStrengthOtherThanStrongOrWeakIsRejected() {
        for value in ["medium", "STRONG", "Weak", "", " strong"] {
            assertRejected("sms_keywords.strength", value) {
                try decodeChangingFirstKeyword { $0["strength"] = value }
            }
        }
        assertRejected("sms_keywords.strength") { try decodeChangingFirstKeyword { $0["strength"] = 1 } }
    }
}
