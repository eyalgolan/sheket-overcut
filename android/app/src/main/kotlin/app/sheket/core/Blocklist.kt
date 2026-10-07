package app.sheket.core

/**
 * A blocklist that passed schema 1 validation (spec 6.1), reduced to what the
 * Android app uses.
 *
 * [BlocklistParser] validates the SMS fields too, so a document with a bad SMS
 * field is rejected whole, but does not keep them: SMS filtering is out of
 * scope on Android v1.
 *
 * @property version generation time in Unix seconds; a newer list has a greater version.
 * @property generatedAt the `generated_at` string exactly as received.
 * @property callNumbers exact caller numbers, E.164.
 * @property callPrefixes E.164 prefixes; any caller starting with one is blocked.
 */
data class Blocklist(
    val version: Long,
    val generatedAt: String,
    val callNumbers: Set<String>,
    val callPrefixes: Set<String>,
)
