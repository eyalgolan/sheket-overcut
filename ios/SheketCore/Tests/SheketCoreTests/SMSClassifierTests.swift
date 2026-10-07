import Foundation
import SheketCore
import XCTest

/// Tests for `SMSClassifier` (spec section 6.1): allow list, then sender
/// list, then one strong or two distinct weak keywords, matched as
/// substrings on Unicode scalars.
final class SMSClassifierTests: XCTestCase {
    private func classifier(
        senders: [String] = [],
        allow: [String] = [],
        strong: [String] = [],
        weak: [String] = []
    ) -> SMSClassifier {
        SMSClassifier(Blocklist(
            version: 1,
            generatedAt: "2026-10-05T12:00:00Z",
            callNumbers: [],
            callPrefixes: [],
            smsSenders: senders,
            smsKeywords: strong.map { Keyword(text: $0, strength: .strong) }
                + weak.map { Keyword(text: $0, strength: .weak) },
            smsAllowSenders: allow
        ))
    }

    // MARK: - Rule order

    func testAllowListComesFirst() {
        let c = classifier(senders: ["Bank"], allow: ["Bank"], strong: ["הודעת בחירות"])
        XCTAssertEqual(c.classify(sender: "Bank", text: "הודעת בחירות"), .allow)
    }

    func testSenderListComesBeforeKeywords() {
        let c = classifier(senders: ["ExampleParty"], strong: ["הודעת בחירות"])
        XCTAssertEqual(c.classify(sender: "ExampleParty", text: "שלום"), .junk)
        XCTAssertEqual(c.classify(sender: "Other", text: "שלום"), .allow)
    }

    func testListSendersAreNormalisedOnBothSides() {
        let c = classifier(senders: ["ExampleList", "+972555004321"], allow: ["ExampleAllow"])
        XCTAssertEqual(c.classify(sender: "EXAMPLELIST", text: nil), .junk)
        XCTAssertEqual(c.classify(sender: "  examplelist ", text: nil), .junk)
        XCTAssertEqual(c.classify(sender: "055-500-4321", text: nil), .junk)
        XCTAssertEqual(c.classify(sender: "972555004321", text: nil), .junk)
        XCTAssertEqual(c.classify(sender: "exampleallow", text: nil), .allow)
    }

    func testOneStrongKeywordIsJunk() {
        let c = classifier(strong: ["הודעת בחירות"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "זוהי הודעת בחירות מטעם"), .junk)
    }

    func testOneWeakKeywordIsNotEnough() {
        let c = classifier(weak: ["בחירות", "קלפי"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "יום הבחירות"), .allow)
        // The same weak keyword twice is still one distinct keyword.
        XCTAssertEqual(c.classify(sender: "Unknown", text: "בחירות בחירות בחירות"), .allow)
    }

    func testTwoDistinctWeakKeywordsAreJunk() {
        let c = classifier(weak: ["בחירות", "קלפי"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "בחירות: מחר לקלפי"), .junk)
    }

    func testTextIsNormalisedBeforeMatching() {
        let c = classifier(strong: ["הודעת בחירות", "голосуйте за"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "הוֹדָעַת בְּחִירוֹת"), .junk) // niqqud
        XCTAssertEqual(c.classify(sender: "Unknown", text: "ГОЛОСУЙТЕ ЗА нас"), .junk) // case
    }

    func testKeywordsAreNormalisedToo() {
        let c = classifier(strong: ["ГОЛОСУЙТЕ ЗА"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "голосуйте за нас"), .junk)
    }

    func testKeywordLongerThanTheTextDoesNotMatch() {
        let c = classifier(strong: ["הודעת בחירות"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "הודעת"), .allow)
        XCTAssertEqual(c.classify(sender: "Unknown", text: ""), .allow)
    }

    // MARK: - AC-11

    func testKeywordThatNormalisesToEmptyIsDropped() {
        // Niqqud only: NFKC then niqqud removal leaves "". An empty keyword
        // would be a substring of every message.
        let c = classifier(strong: ["\u{05B0}\u{05BC}"], weak: ["\u{05B4}", "\u{05B9}"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "שלום"), .allow)
        XCTAssertEqual(c.classify(sender: "Unknown", text: ""), .allow)
        XCTAssertEqual(c.classify(sender: "Unknown", text: nil), .allow)
    }

    func testWeakSpellingsThatNormaliseAlikeCountOnce() {
        let c = classifier(weak: ["בחירות", "בְּחִירוֹת", "ВЫБОРЫ", "выборы"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "בחירות"), .allow)
        XCTAssertEqual(c.classify(sender: "Unknown", text: "выборы"), .allow)
        // Two genuinely distinct weak keywords still count as two.
        XCTAssertEqual(c.classify(sender: "Unknown", text: "בחירות выборы"), .junk)
    }

    func testSenderThatNormalisesToNilStillReachesTheKeywordRule() {
        // "Example Party" normalises to nil, so the allow entry is dropped and
        // the sender cannot match it; the keyword rule still applies.
        let c = classifier(allow: ["Example Party"], strong: ["הודעת בחירות"])
        XCTAssertNil(SenderNormalizer.normalize("Example Party"))
        XCTAssertEqual(c.classify(sender: "Example Party", text: "הודעת בחירות"), .junk)
        XCTAssertEqual(c.classify(sender: "", text: "הודעת בחירות"), .junk)
        XCTAssertEqual(c.classify(sender: "   ", text: "שלום"), .allow)
    }

    func testNilTextIsTreatedAsEmpty() {
        let c = classifier(senders: ["ExampleList"], allow: ["ExampleAllow"], strong: ["הודעת בחירות"],
                           weak: ["בחירות", "קלפי"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: nil), c.classify(sender: "Unknown", text: ""))
        XCTAssertEqual(c.classify(sender: "Unknown", text: nil), .allow)
        XCTAssertEqual(c.classify(sender: "ExampleList", text: nil), .junk)
        XCTAssertEqual(c.classify(sender: "ExampleAllow", text: nil), .allow)
    }

    func testMatchingIsOnScalars() {
        // An Arabic keyword without the shadda does not match text with it.
        let withoutShadda = "صوتوا للقائمة"
        let withShadda = "صوّتوا للقائمة"
        let c = classifier(strong: [withoutShadda])
        XCTAssertEqual(c.classify(sender: "Unknown", text: withShadda), .allow)
        XCTAssertEqual(c.classify(sender: "Unknown", text: withoutShadda), .junk)

        let both = classifier(strong: [withShadda])
        XCTAssertEqual(both.classify(sender: "Unknown", text: withShadda), .junk)
        XCTAssertEqual(both.classify(sender: "Unknown", text: withoutShadda), .allow)
    }

    func testKeywordMatchesInsideAWordByScalars() {
        // Substring, not word, matching: "צביע לליכוד" is inside "להצביע לליכוד".
        let c = classifier(strong: ["צביע לליכוד"])
        XCTAssertEqual(c.classify(sender: "Unknown", text: "כולם להצביע לליכוד!"), .junk)
    }

    func testVerdictRawValuesMatchTheCorpus() {
        XCTAssertEqual(SMSVerdict(rawValue: "allow"), .allow)
        XCTAssertEqual(SMSVerdict(rawValue: "junk"), .junk)
        XCTAssertNil(SMSVerdict(rawValue: "block"))
    }
}
