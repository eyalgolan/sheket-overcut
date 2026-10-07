import Foundation

/// The outcome of the SMS rule in spec section 6.1. Raw values match the
/// `expect` field of the `sms` cases in `contract/corpus.json`.
public enum SMSVerdict: String, Equatable {
    case allow
    case junk
}

/// Applies the SMS rule of spec section 6.1 to one message:
/// sender in `sms_allow_senders` -> allow; sender in `sms_senders` -> junk;
/// text contains at least one `strong` keyword or at least two distinct
/// `weak` keywords -> junk; otherwise allow.
///
/// Senders and keywords are normalised once, at init. All comparisons are
/// on Unicode scalars, not `String`, because Swift `String` equality and
/// `contains` use canonical equivalence while the backend and Android
/// compare code points; with scalars an Arabic keyword without the shadda
/// does not match text that has it.
public struct SMSClassifier {
    private let allowSenders: Set<[Unicode.Scalar]>
    private let junkSenders: Set<[Unicode.Scalar]>
    private let strongKeywords: [[Unicode.Scalar]]
    private let weakKeywords: [[Unicode.Scalar]]

    /// Prepares `list` for classification. Sender entries that do not
    /// normalise are dropped. Keywords that normalise to empty text are
    /// dropped, so one bad entry cannot junk every message; keywords that
    /// normalise alike count once within their strength.
    public init(_ list: Blocklist) {
        allowSenders = Self.senderSet(list.smsAllowSenders)
        junkSenders = Self.senderSet(list.smsSenders)

        var strong: [[Unicode.Scalar]] = []
        var weak: [[Unicode.Scalar]] = []
        var seenStrong: Set<[Unicode.Scalar]> = []
        var seenWeak: Set<[Unicode.Scalar]> = []
        for keyword in list.smsKeywords {
            let scalars = Array(TextNormalizer.normalize(keyword.text).unicodeScalars)
            if scalars.isEmpty { continue }
            switch keyword.strength {
            case .strong:
                if seenStrong.insert(scalars).inserted { strong.append(scalars) }
            case .weak:
                if seenWeak.insert(scalars).inserted { weak.append(scalars) }
            }
        }
        strongKeywords = strong
        weakKeywords = weak
    }

    /// Classifies one message by the ordered SMS rule of spec section 6.1.
    /// A sender that does not normalise skips both sender rules; a `nil`
    /// text is treated as empty.
    public func classify(sender: String, text: String?) -> SMSVerdict {
        if let normalized = SenderNormalizer.normalize(sender) {
            let scalars = Array(normalized.unicodeScalars)
            if allowSenders.contains(scalars) { return .allow }
            if junkSenders.contains(scalars) { return .junk }
        }

        let body = Array(TextNormalizer.normalize(text ?? "").unicodeScalars)
        if strongKeywords.contains(where: { Self.contains(body, $0) }) {
            return .junk
        }
        var weakHits = 0
        for keyword in weakKeywords where Self.contains(body, keyword) {
            weakHits += 1
            if weakHits >= 2 { return .junk }
        }
        return .allow
    }

    private static func senderSet(_ entries: [String]) -> Set<[Unicode.Scalar]> {
        Set(entries.compactMap { SenderNormalizer.normalize($0) }.map { Array($0.unicodeScalars) })
    }

    /// Whether `needle` occurs in `haystack` as a contiguous run of scalars
    /// (spec section 6.1: substring matching, no regular expressions).
    /// `needle` is never empty: empty keywords are dropped at init.
    private static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }
}
