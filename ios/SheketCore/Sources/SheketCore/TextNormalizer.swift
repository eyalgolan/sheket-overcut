import Foundation

/// Normalises text before keyword matching, as spec section 6.1 requires:
/// "NFKC, Hebrew niqqud removed, lowercased".
public enum TextNormalizer {
    /// Hebrew points and cantillation marks that are removed. Only the
    /// nonspacing marks (`Mn`) in this range are dropped, so maqaf (U+05BE),
    /// paseq (U+05C0), sof pasuq (U+05C3) and nun hafukha (U+05C6) stay.
    /// Provisional default from design Open Question 3 (issue #17, comment
    /// 6028072819: https://github.com/eyalgolan/sheket-overcut/issues/17#issuecomment-6028072819).
    private static let hebrewMarks: ClosedRange<UInt32> = 0x0591...0x05C7

    /// Returns `s` after NFKC, removal of Hebrew niqqud and cantillation, and
    /// lowercasing, in that order.
    public static func normalize(_ s: String) -> String {
        let composed = s.precomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in composed.unicodeScalars
        where !(hebrewMarks.contains(scalar.value)
                && scalar.properties.generalCategory == .nonspacingMark) {
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }
}
