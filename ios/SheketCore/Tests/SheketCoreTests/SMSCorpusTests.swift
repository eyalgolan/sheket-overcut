import Foundation
import SheketCore
import XCTest

/// Runs every `sms` case in `contract/corpus.json` against `SMSClassifier`,
/// using the list named in the case's `blocklist` field (spec section 11).
final class SMSCorpusTests: XCTestCase {
    func testSMSCorpus() throws {
        let cases = try Contract.corpusSection("sms")
        // An empty section would pass silently instead of testing anything.
        XCTAssertFalse(cases.isEmpty, "contract/corpus.json has no sms cases")

        var classifiers: [String: SMSClassifier] = [:]
        for (name, file) in Contract.blocklistFiles {
            classifiers[name] = SMSClassifier(try Contract.blocklist(file))
        }

        for (index, testCase) in cases.enumerated() {
            let why = testCase["why"] as? String ?? "<no why>"
            let label = "sms case \(index), why: \(why)"
            guard let listName = testCase["blocklist"] as? String,
                  let classifier = classifiers[listName] else {
                XCTFail("\(label): unknown blocklist \(String(describing: testCase["blocklist"]))")
                continue
            }
            guard let sender = testCase["sender"] as? String else {
                XCTFail("\(label): \"sender\" is not a string")
                continue
            }
            let text: String?
            switch testCase["text"] {
            case is NSNull:
                text = nil
            case let value as String:
                text = value
            default:
                XCTFail("\(label): \"text\" is neither a string nor null")
                continue
            }
            guard let expectName = testCase["expect"] as? String,
                  let expected = SMSVerdict(rawValue: expectName) else {
                XCTFail("\(label): unknown expect \(String(describing: testCase["expect"]))")
                continue
            }
            XCTAssertEqual(
                classifier.classify(sender: sender, text: text),
                expected,
                "\(label); blocklist: \(listName), sender: \(String(reflecting: sender))"
            )
        }
    }
}
