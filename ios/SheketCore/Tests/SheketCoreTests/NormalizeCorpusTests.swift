import Foundation
import XCTest
@testable import SheketCore

/// Runs the `normalize` section of `contract/corpus.json` against
/// `SenderNormalizer`, mirroring `backend/tests/test_normalize.py`.
///
/// The corpus is read in place from the repository's `contract/` directory,
/// read-only; it is never copied into the package (`contract/README.md`).
final class NormalizeCorpusTests: XCTestCase {
    private struct NormalizeCase: Decodable {
        let input: String
        let output: String?

        enum CodingKeys: String, CodingKey {
            case input = "in"
            case output = "out"
        }
    }

    private struct Corpus: Decodable {
        let normalize: [NormalizeCase]
    }

    /// `<repo>/contract/corpus.json`, found from this file's path:
    /// `<repo>/ios/SheketCore/Tests/SheketCoreTests/NormalizeCorpusTests.swift`.
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SheketCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // SheketCore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("contract")
        .appendingPathComponent("corpus.json")

    private func loadNormalizeCases() throws -> [NormalizeCase] {
        let data: Data
        do {
            data = try Data(contentsOf: Self.corpusURL)
        } catch {
            XCTFail("cannot read \(Self.corpusURL.path): \(error)")
            throw error
        }
        let cases = try JSONDecoder().decode(Corpus.self, from: data).normalize
        // An empty list would pass every loop below without checking anything.
        XCTAssertFalse(cases.isEmpty, "contract/corpus.json has no normalize cases")
        return cases
    }

    func testNormalizeCorpus() throws {
        for c in try loadNormalizeCases() {
            XCTAssertEqual(SenderNormalizer.normalize(c.input), c.output, "in: \(c.input.debugDescription)")
        }
    }

    func testPhoneOutputsAreE164() throws {
        let phones = try loadNormalizeCases()
            .compactMap(\.output)
            .filter { $0.hasPrefix("+") }
        XCTAssertFalse(phones.isEmpty, "contract/corpus.json has no phone normalize outputs")
        for out in phones {
            XCTAssertTrue(SenderNormalizer.isE164(out), out)
        }
    }
}
