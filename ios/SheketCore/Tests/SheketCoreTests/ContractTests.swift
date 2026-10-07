import Foundation
import SheketCore
import XCTest

/// Tests for the test harness itself (`Contract.swift`).
final class ContractTests: XCTestCase {
    func testRepositoryRootIsFoundFromThisFile() throws {
        let root = Contract.repositoryRoot
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/SheketCore/Package.swift").path),
            "not the repository root: \(root.path)"
        )
        XCTAssertEqual(Contract.directory.lastPathComponent, "contract")
        for name in ["corpus.json", "seed-blocklist.json", "test-blocklist.json", "blocklist.schema.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: Contract.url(name).path),
                          "missing: \(Contract.url(name).path)")
        }
    }

    func testMissingFileFailsWithTheFullPath() {
        let name = "no-such-file-\(UUID().uuidString).json"
        let fullPath = Contract.url(name).path
        XCTAssertThrowsError(try Contract.data(name)) { error in
            XCTAssertTrue(String(describing: error).contains(fullPath), "\(error)")
            XCTAssertEqual((error as? Contract.FileError)?.path, fullPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fullPath),
                       "reading a missing contract file must not create it")
    }

    func testReadingDoesNotModifyContractFiles() throws {
        let names = ["corpus.json", "seed-blocklist.json", "test-blocklist.json"]
        func snapshot() throws -> [(Data, Date?)] {
            try names.map { name in
                let attributes = try FileManager.default.attributesOfItem(atPath: Contract.url(name).path)
                return (try Data(contentsOf: Contract.url(name)), attributes[.modificationDate] as? Date)
            }
        }
        let before = try snapshot()
        _ = try Contract.corpusSection("normalize")
        _ = try Contract.corpusSection("sms")
        _ = try Contract.blocklist("seed-blocklist.json")
        _ = try Contract.blocklist("test-blocklist.json")
        let after = try snapshot()
        XCTAssertEqual(before.map(\.0), after.map(\.0))
        XCTAssertEqual(before.map(\.1), after.map(\.1))
    }
}
