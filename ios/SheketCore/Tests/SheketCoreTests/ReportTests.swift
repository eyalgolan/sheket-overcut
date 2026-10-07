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
}
