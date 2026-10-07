import Foundation
import SheketCore
import XCTest

/// Acceptance tests for `ReportRequest`, `ReportOutcome` and `ReportPolicy`,
/// checked against `_validate` in `backend/src/sheket/report.py` and spec
/// sections 6.2 and 7.
final class ReportTests: XCTestCase {
    // MARK: - Helpers

    private let id = "3f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11"
    private let version = "1.0.0"

    /// Builds a request with valid defaults for every field not given.
    private func make(
        installID: String? = nil,
        kind: ReportKind = .sms,
        rawSender: String = "+972555001234",
        text: String? = nil,
        appVersion: String? = nil
    ) -> Result<Data, ReportFieldError> {
        ReportRequest.make(
            installID: installID ?? id,
            kind: kind,
            rawSender: rawSender,
            text: text,
            appVersion: appVersion ?? version
        )
    }

    /// Decodes a successful result into a JSON object; fails on a failure.
    private func object(
        _ result: Result<Data, ReportFieldError>,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(try? result.get(), "expected success, got \(result)",
                                 file: file, line: line)
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? [String: Any], file: file, line: line)
    }

    /// The failure of a result, or nil on success.
    private func failure(_ result: Result<Data, ReportFieldError>) -> ReportFieldError? {
        if case .failure(let error) = result {
            return error
        }
        return nil
    }

    // MARK: - AC-1: body shape

    func testSMSBodyHasAllFields() throws {
        let body = try object(make(kind: .sms, rawSender: "055-500-1234", text: "שלום"))
        XCTAssertEqual(
            Set(body.keys),
            ["install_id", "platform", "kind", "sender", "text", "app_version"]
        )
        XCTAssertEqual(body["install_id"] as? String, id)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["kind"] as? String, "sms")
        XCTAssertEqual(body["sender"] as? String, "+972555001234")
        XCTAssertEqual(body["text"] as? String, "שלום")
        XCTAssertEqual(body["app_version"] as? String, version)
    }

    // MARK: - AC-2: text presence

    func testSMSWithoutTextHasNoTextKey() throws {
        let body = try object(make(kind: .sms, text: nil))
        XCTAssertEqual(Set(body.keys), ["install_id", "platform", "kind", "sender", "app_version"])
    }

    func testCallWithoutTextSucceeds() throws {
        let body = try object(make(kind: .call, rawSender: "+972555001234", text: nil))
        XCTAssertEqual(body["kind"] as? String, "call")
        XCTAssertNil(body["text"])
        XCTAssertEqual(body.count, 5)
    }

    func testCallWithTextFails() {
        XCTAssertEqual(failure(make(kind: .call, rawSender: "+972555001234", text: "hi")), .text)
    }

    func testSMSWithEmptyTextKeepsIt() throws {
        let body = try object(make(kind: .sms, text: ""))
        XCTAssertEqual(body["text"] as? String, "")
    }

    // MARK: - AC-3: install_id

    func testInvalidInstallIDs() {
        let rejected = [
            id.uppercased(),
            "{" + id + "}",
            id.replacingOccurrences(of: "-", with: ""),
            "urn:uuid:" + id,
            "g" + String(id.dropFirst()), // one non-hex character
            "",
        ]
        for s in rejected {
            XCTAssertEqual(failure(make(installID: s)), .installID, String(reflecting: s))
        }
    }

    func testInstallIDIsCheckedBeforeSender() {
        XCTAssertEqual(failure(make(installID: "", rawSender: "")), .installID)
    }

    // MARK: - AC-3: sender

    func testEmptySenderFails() {
        for kind in [ReportKind.sms, .call] {
            for s in ["", "   "] {
                XCTAssertEqual(failure(make(kind: kind, rawSender: s)), .sender,
                               "\(kind) \(String(reflecting: s))")
            }
        }
    }

    func testSenderIDIsAcceptedForSMSButNotForCall() throws {
        // The backend's normalize_sender("Unknown") is the valid sender ID
        // "unknown", so it is accepted for SMS but fails E.164 for a call,
        // which is what the backend returns.
        XCTAssertEqual(failure(make(kind: .call, rawSender: "Unknown")), .sender)
        let body = try object(make(kind: .sms, rawSender: "Unknown"))
        XCTAssertEqual(body["sender"] as? String, "unknown")
    }

    func testStarCodeIsAcceptedForSMSButNotForCall() throws {
        XCTAssertEqual(failure(make(kind: .call, rawSender: "*2700")), .sender)
        let body = try object(make(kind: .sms, rawSender: "*2700"))
        XCTAssertEqual(body["sender"] as? String, "*2700")
    }

    // MARK: - AC-3: text

    func testTextOverLimitFails() {
        XCTAssertEqual(failure(make(kind: .sms, text: String(repeating: "a", count: 1001))), .text)
    }

    func testThousandNonBMPScalarsPass() throws {
        let text = String(repeating: "😀", count: 1000)
        let body = try object(make(kind: .sms, text: text))
        XCTAssertEqual(body["text"] as? String, text)
    }

    func testTextLimitCountsScalarsNotCharacters() throws {
        // 1,001 scalars that form a single Character.
        let over = "e" + String(repeating: "\u{0301}", count: 1000)
        XCTAssertEqual(over.unicodeScalars.count, 1001)
        XCTAssertEqual(over.count, 1)
        XCTAssertEqual(failure(make(kind: .sms, text: over)), .text)

        let atLimit = "e" + String(repeating: "\u{0301}", count: 999)
        XCTAssertEqual(atLimit.unicodeScalars.count, 1000)
        _ = try object(make(kind: .sms, text: atLimit))
    }

    // MARK: - AC-3: app_version

    func testInvalidAppVersions() {
        let rejected = ["1.0.0\n", "", String(repeating: "1", count: 33), "1.0 beta", "١.0"]
        for s in rejected {
            XCTAssertEqual(failure(make(appVersion: s)), .appVersion, String(reflecting: s))
        }
    }

    func testValidAppVersions() throws {
        for s in [String(repeating: "1", count: 32), "1.0.0+build-7"] {
            let body = try object(make(appVersion: s))
            XCTAssertEqual(body["app_version"] as? String, s)
        }
    }

    // MARK: - AC-3: order

    func testTextIsCheckedBeforeAppVersion() {
        XCTAssertEqual(failure(make(kind: .call, text: "hi", appVersion: "")), .text)
    }

    // MARK: - AC-4: body size

    func testLargestValidBodyFitsBackendLimit() throws {
        let result = make(
            kind: .sms,
            rawSender: "+972555001234",
            text: String(repeating: "😀", count: 1000),
            appVersion: String(repeating: "1", count: 32)
        )
        let data = try result.get()
        XCTAssertLessThanOrEqual(data.count, 16384) // MAX_BODY_BYTES
    }

    // MARK: - AC-5: ReportOutcome.from

    func testOutcomeFromResponse() {
        XCTAssertEqual(ReportOutcome.from(status: 202, body: nil), .sent)
        XCTAssertEqual(ReportOutcome.from(status: 400, body: Data(#"{"error":"sender"}"#.utf8)),
                       .rejected("sender"))
        XCTAssertEqual(ReportOutcome.from(status: 400, body: nil), .rejected(nil))
        XCTAssertEqual(ReportOutcome.from(status: 400, body: Data("not json".utf8)), .rejected(nil))
        XCTAssertEqual(ReportOutcome.from(status: 400, body: Data(#"{"error":1}"#.utf8)),
                       .rejected(nil))
        XCTAssertEqual(ReportOutcome.from(status: 429, body: nil), .retryable(rateLimited: true))
        XCTAssertEqual(ReportOutcome.from(status: 500, body: nil), .retryable(rateLimited: false))
        XCTAssertEqual(ReportOutcome.from(status: 503, body: nil), .retryable(rateLimited: false))
        XCTAssertEqual(ReportOutcome.from(status: nil, body: nil), .retryable(rateLimited: false))
        XCTAssertEqual(ReportOutcome.from(status: 404, body: nil), .retryable(rateLimited: false))
    }

    // MARK: - REQ-3: retry policy

    func testMaxAttemptsIsOneRetry() {
        XCTAssertEqual(ReportPolicy.maxAttempts, 2)
    }

    // MARK: - Edge cases: wire names

    func testFieldErrorRawValuesAreBackendFieldNames() {
        XCTAssertEqual(ReportFieldError.installID.rawValue, "install_id")
        XCTAssertEqual(ReportFieldError.sender.rawValue, "sender")
        XCTAssertEqual(ReportFieldError.text.rawValue, "text")
        XCTAssertEqual(ReportFieldError.appVersion.rawValue, "app_version")
    }

    func testKindRawValuesAreBackendKinds() {
        XCTAssertEqual(ReportKind.call.rawValue, "call")
        XCTAssertEqual(ReportKind.sms.rawValue, "sms")
    }

    // MARK: - Edge cases: install_id

    func testValidInstallIDsPass() throws {
        let valid = [
            "00000000-0000-0000-0000-000000000000",
            "ffffffff-ffff-ffff-ffff-ffffffffffff",
            "01234567-89ab-cdef-0123-456789abcdef",
        ]
        for s in valid {
            let body = try object(make(installID: s))
            XCTAssertEqual(body["install_id"] as? String, s)
        }
    }

    func testMalformedInstallIDShapesFail() {
        let rejected = [
            String(id.dropLast()), // 35 characters
            id + "0", // 37 characters
            " " + String(id.dropFirst()), // leading space
            String(id.dropLast()) + "\n", // trailing newline, still 36
            "3f0e4c1e6-a0b-4f5e-9d0a-2f6c1b7a9e11", // hyphen moved
            "3f0e4c1e-6a0b-4f5e-9d0a_2f6c1b7a9e11", // "_" instead of "-"
            "3F0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11", // one uppercase hex digit
            "３f0e4c1e-6a0b-4f5e-9d0a-2f6c1b7a9e11", // fullwidth digit
        ]
        for s in rejected {
            XCTAssertEqual(failure(make(installID: s)), .installID, String(reflecting: s))
        }
    }

    // MARK: - Edge cases: sender

    func testCallSenderIsNormalisedToE164() throws {
        let body = try object(make(kind: .call, rawSender: "055-500-1234"))
        XCTAssertEqual(body["sender"] as? String, "+972555001234")
    }

    func testShortServiceNumberIsAcceptedForSMSButNotForCall() throws {
        XCTAssertEqual(failure(make(kind: .call, rawSender: "100")), .sender)
        let body = try object(make(kind: .sms, rawSender: "100"))
        XCTAssertEqual(body["sender"] as? String, "100")
    }

    func testInvalidSenderIDsFail() {
        // Over 20 scalars after folding, inner whitespace, and the
        // international dialling prefix all normalise to nil.
        for s in [String(repeating: "a", count: 21), "Bank Leumi", "00972555001234"] {
            XCTAssertEqual(failure(make(kind: .sms, rawSender: s)), .sender, String(reflecting: s))
        }
    }

    // MARK: - Edge cases: text

    func testTextIsSentExactlyAsGiven() throws {
        let text = "  Hello\nWORLD \u{200F} "
        let body = try object(make(kind: .sms, text: text))
        XCTAssertEqual(body["text"] as? String, text)
    }

    func testTextLimitBoundaries() throws {
        _ = try object(make(kind: .sms, text: String(repeating: "a", count: 1000)))
        XCTAssertEqual(failure(make(kind: .sms, text: String(repeating: "😀", count: 1001))), .text)
    }

    func testCallWithEmptyTextFails() {
        // The backend checks `text is not None`, so even "" on a call fails.
        XCTAssertEqual(failure(make(kind: .call, text: "")), .text)
    }

    // MARK: - Edge cases: app_version

    func testAppVersionAcceptsEveryAllowedCharacter() throws {
        let all = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-"
        var chunk = ""
        for c in all {
            chunk.append(c)
            if chunk.count == 32 {
                _ = try object(make(appVersion: chunk))
                chunk = ""
            }
        }
        if !chunk.isEmpty { _ = try object(make(appVersion: chunk)) }
        _ = try object(make(appVersion: "1"))
    }

    func testAppVersionRejectsOtherCharacters() {
        for s in ["1.0_0", "1.0/0", "v1.0\r", " 1.0", "1.0 ", "１.0", "é", "1,0"] {
            XCTAssertEqual(failure(make(appVersion: s)), .appVersion, String(reflecting: s))
        }
    }

    // MARK: - Edge cases: order

    func testSenderIsCheckedBeforeText() {
        XCTAssertEqual(failure(make(kind: .call, rawSender: "Unknown", text: "hi")), .sender)
    }

    func testSenderIsCheckedBeforeAppVersion() {
        XCTAssertEqual(failure(make(rawSender: "", appVersion: "")), .sender)
    }

    func testInstallIDIsCheckedFirst() {
        XCTAssertEqual(
            failure(make(installID: "x", kind: .call, rawSender: "", text: "hi", appVersion: "")),
            .installID
        )
    }

    // MARK: - Edge cases: encoding

    func testEncodingIsDeterministicAndValidUTF8JSON() throws {
        let a = try make(kind: .sms, rawSender: "055-500-1234", text: "שלום 😀").get()
        let b = try make(kind: .sms, rawSender: "055-500-1234", text: "שלום 😀").get()
        XCTAssertEqual(a, b)
        XCTAssertNotNil(String(data: a, encoding: .utf8))
        for value in try object(.success(a)).values {
            XCTAssertTrue(value is String, "every body value is a string")
        }
    }

    func testLargestValidBodyWithLongestSenderFitsBackendLimit() throws {
        // 1,000 non-BMP text scalars, a 20-scalar non-ASCII sender ID and a
        // 32-character app version.
        let sender = String(repeating: "א", count: 20)
        let data = try make(
            kind: .sms,
            rawSender: sender,
            text: String(repeating: "😀", count: 1000),
            appVersion: String(repeating: "1", count: 32)
        ).get()
        XCTAssertLessThanOrEqual(data.count, 16384)
        XCTAssertEqual(try object(.success(data))["sender"] as? String, sender)
    }

    // MARK: - Edge cases: ReportOutcome.from

    func testOutcomeFromOtherStatusesIsRetryableWithoutRateLimit() {
        for status in [0, 200, 201, 204, 301, 304, 401, 403, 404, 405, 413, 499, 501, 502, 504, 599] {
            XCTAssertEqual(ReportOutcome.from(status: status, body: nil),
                           .retryable(rateLimited: false), "status \(status)")
        }
    }

    func testOutcomeIgnoresBodyExceptOn400() {
        let body = Data(#"{"error":"sender"}"#.utf8)
        XCTAssertEqual(ReportOutcome.from(status: 202, body: body), .sent)
        XCTAssertEqual(ReportOutcome.from(status: 429, body: body), .retryable(rateLimited: true))
        XCTAssertEqual(ReportOutcome.from(status: 500, body: body), .retryable(rateLimited: false))
    }

    func testOutcomeFrom400WithUnusualBodies() {
        let cases: [(String, String?)] = [
            (#"{"error":"install_id"}"#, "install_id"),
            (#"{"error":"body"}"#, "body"),
            (#"{"error":"app_version","extra":1}"#, "app_version"),
            ("{}", nil),
            (#"["sender"]"#, nil),
            (#""sender""#, nil),
            (#"{"error":null}"#, nil),
            (#"{"error":{"field":"sender"}}"#, nil),
            ("", nil),
        ]
        for (json, expected) in cases {
            XCTAssertEqual(ReportOutcome.from(status: 400, body: Data(json.utf8)),
                           .rejected(expected), json)
        }
    }
}
