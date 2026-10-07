import Foundation
import IdentityLookup
import SheketCore

/// The SMS filter. Answers only `.junk` or `.allow`, offline.
///
/// The list in the app group is decoded once per modification date and
/// cached. When it is missing or does not decode, the bundled seed list is
/// used, so filtering works before first unlock and before the app has ever
/// been opened. With no usable list at all, every message is allowed.
final class MessageFilterExtension: ILMessageFilterExtension {}

extension MessageFilterExtension: ILMessageFilterQueryHandling {
    func handle(
        _ queryRequest: ILMessageFilterQueryRequest,
        context: ILMessageFilterExtensionContext,
        completion: @escaping (ILMessageFilterQueryResponse) -> Void
    ) {
        let response = ILMessageFilterQueryResponse()
        let verdict = Self.classifier()?.classify(
            sender: queryRequest.sender ?? "",
            text: queryRequest.messageBody
        )
        response.action = verdict == .junk ? .junk : .allow
        completion(response)
    }
}

extension MessageFilterExtension {
    /// Guards `cached`, `seed` and `seedBuilt`.
    private static let lock = NSLock()

    /// The classifier for the app-group list at a given modification date;
    /// nil when that file did not decode, so it is not re-decoded per message.
    private static var cached: (modificationDate: Date, classifier: SMSClassifier?)?

    /// The classifier for the bundled seed list, built at most once.
    private static var seed: SMSClassifier?
    private static var seedBuilt = false

    /// The app-group list's classifier, else the seed's, else nil.
    /// Read-only.
    private static func classifier() -> SMSClassifier? {
        lock.lock()
        defer { lock.unlock() }

        if let container = AppGroup.containerURL() {
            let url = container.appendingPathComponent(BlocklistStore.blocklistFileName)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let date = attributes?[.modificationDate] as? Date {
                let classifier: SMSClassifier?
                if let cached = cached, cached.modificationDate == date {
                    classifier = cached.classifier
                } else {
                    classifier = BlocklistStore(directory: container).current().map(SMSClassifier.init)
                    cached = (date, classifier)
                }
                if let classifier = classifier {
                    return classifier
                }
            }
        }

        if !seedBuilt {
            seedBuilt = true
            seed = Bundle.main.url(forResource: "seed-blocklist", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? BlocklistDecoder.decode($0) }
                .map(SMSClassifier.init)
        }
        return seed
    }
}
