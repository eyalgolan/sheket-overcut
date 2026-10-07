import Foundation
import SheketCore

/// Read-only access to the shared files in `contract/` (spec section 11).
///
/// The files are read in place: SwiftPM resources cannot point outside the
/// package, and the contract README says nobody keeps a copy. Nothing here
/// ever writes to `contract/`.
enum Contract {
    /// A contract file that does not exist or cannot be read.
    struct FileError: Error, CustomStringConvertible, LocalizedError {
        let path: String
        let reason: String

        var description: String { "contract file \(reason): \(path)" }
        var errorDescription: String? { description }
    }

    /// A contract file whose content is not what the tests expect.
    struct ShapeError: Error, CustomStringConvertible, LocalizedError {
        let message: String

        var description: String { message }
        var errorDescription: String? { message }
    }

    /// The repository root, found from this file's path by removing 5
    /// components: `Contract.swift`, `SheketCoreTests`, `Tests`,
    /// `SheketCore` and `ios`.
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    static let directory = repositoryRoot.appendingPathComponent("contract", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// The bytes of `contract/<name>`. Throws with the full path if the file
    /// is missing or unreadable.
    static func data(_ name: String) throws -> Data {
        let path = url(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileError(path: path, reason: "missing")
        }
        do {
            return try Data(contentsOf: url(name))
        } catch {
            throw FileError(path: path, reason: "unreadable (\(error))")
        }
    }

    /// `contract/<name>` parsed with `JSONSerialization`.
    static func json(_ name: String) throws -> Any {
        let bytes = try data(name)
        do {
            return try JSONSerialization.jsonObject(with: bytes)
        } catch {
            throw ShapeError(message: "contract file is not JSON (\(error)): \(url(name).path)")
        }
    }

    /// `contract/<name>` as a JSON object.
    static func object(_ name: String) throws -> [String: Any] {
        guard let object = try json(name) as? [String: Any] else {
            throw ShapeError(message: "contract file is not a JSON object: \(url(name).path)")
        }
        return object
    }

    /// One section of `contract/corpus.json`, as an array of case objects.
    static func corpusSection(_ section: String) throws -> [[String: Any]] {
        guard let cases = try object("corpus.json")[section] as? [[String: Any]] else {
            throw ShapeError(message: "corpus.json has no \"\(section)\" array of objects: \(url("corpus.json").path)")
        }
        return cases
    }

    /// File names for the `blocklist` field of an `sms` corpus case.
    static let blocklistFiles = [
        "seed": "seed-blocklist.json",
        "test": "test-blocklist.json",
    ]

    /// `contract/<name>`, decoded with the strict `BlocklistDecoder`.
    static func blocklist(_ name: String) throws -> Blocklist {
        try BlocklistDecoder.decode(data(name))
    }
}
