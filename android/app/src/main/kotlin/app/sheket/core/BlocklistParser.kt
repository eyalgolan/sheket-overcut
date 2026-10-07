package app.sheket.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException
import java.util.Locale

/** Outcome of [BlocklistParser.parse]. */
sealed interface ParseResult {
    /** The document is a valid schema 1 blocklist. */
    data class Ok(val blocklist: Blocklist) : ParseResult

    /** The document was rejected whole; the caller keeps its previous list (spec 7). */
    data class Rejected(val reason: String) : ParseResult
}

/**
 * Parses and validates a `GET /v1/blocklist.json` body against schema 1
 * (`contract/blocklist.schema.json`, spec 6.1). Anything that fails is rejected
 * whole (spec 7); [parse] never throws. Arrays and objects nested more than
 * [MAX_DEPTH] deep are rejected before parsing, because the recursive JSON
 * parser would otherwise end in a `StackOverflowError`.
 *
 * Known differences from a Python `jsonschema` check with format checking on,
 * all in the safe direction (rejecting keeps the previous list) and none ever
 * written by the backend:
 * - `generated_at` with a leap second (`:60`), more than 9 fraction digits, or
 *   an offset beyond +/-18:00 is rejected, because `java.time` cannot represent it.
 * - `schema` and `version` must be JSON integer literals: `1.0` is rejected
 *   although JSON Schema counts it as an integer, and a `version` outside the
 *   range of [Long] is rejected.
 */
object BlocklistParser {

    /** The top-level keys, in the schema's `required` order. No others are allowed. */
    val REQUIRED_KEYS: List<String> = listOf(
        "schema",
        "version",
        "generated_at",
        "call_numbers",
        "call_prefixes",
        "sms_senders",
        "sms_keywords",
        "sms_allow_senders",
    )

    /** Must equal `call_prefixes.items.pattern` in `contract/blocklist.schema.json`. */
    val CALL_PREFIX = Regex("^\\+[1-9][0-9]{3,13}$")

    private val REQUIRED_KEY_SET = REQUIRED_KEYS.toSet()
    private val KEYWORD_KEYS = setOf("text", "strength")

    // RFC 3339 date-time shape; java.time then rejects impossible dates such as 2026-02-30.
    private val GENERATED_AT = Regex(
        "[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?([Zz]|[+\\-][0-9]{2}:[0-9]{2})",
    )

    // RFC 8259 integer syntax, so only a true integer literal is accepted.
    private val JSON_INTEGER = Regex("-?(0|[1-9][0-9]*)")

    /** Deepest array/object nesting accepted. A valid schema 1 list is 3 deep. */
    const val MAX_DEPTH = 16

    /** Decodes [bytes] as strict UTF-8 JSON and validates it against schema 1. */
    fun parse(bytes: ByteArray): ParseResult {
        val text = try {
            decodeUtf8(bytes)
        } catch (e: CharacterCodingException) {
            return ParseResult.Rejected("not valid UTF-8")
        }
        if (exceedsDepth(text, MAX_DEPTH)) return ParseResult.Rejected("nesting deeper than $MAX_DEPTH")
        val root = try {
            Json.parseToJsonElement(text)
        } catch (e: Exception) {
            return ParseResult.Rejected("not valid JSON")
        }
        return validate(root)
    }

    private fun validate(root: JsonElement): ParseResult {
        if (root !is JsonObject) return ParseResult.Rejected("root is not an object")
        if (root.keys != REQUIRED_KEY_SET) {
            return ParseResult.Rejected("top-level keys must be exactly $REQUIRED_KEYS")
        }

        if (root.getValue("schema").integerContent() != "1") {
            return ParseResult.Rejected("schema is not 1")
        }
        val version = root.getValue("version").integerContent()?.toLongOrNull()
            ?: return ParseResult.Rejected("version is not an integer")
        val generatedAt = root.getValue("generated_at").stringContent()
            ?.takeIf(::isDateTime)
            ?: return ParseResult.Rejected("generated_at is not an RFC 3339 date-time")

        val callNumbers = root.getValue("call_numbers").stringArray { SenderNormalizer.E164.matches(it) }
            ?: return ParseResult.Rejected("call_numbers is not an array of E.164 numbers")
        val callPrefixes = root.getValue("call_prefixes").stringArray { CALL_PREFIX.matches(it) }
            ?: return ParseResult.Rejected("call_prefixes is not an array of E.164 prefixes")
        root.getValue("sms_senders").stringArray { it.isNotEmpty() }
            ?: return ParseResult.Rejected("sms_senders is not an array of non-empty strings")
        if (!isKeywordArray(root.getValue("sms_keywords"))) {
            return ParseResult.Rejected("sms_keywords is not an array of {text, strength} objects")
        }
        root.getValue("sms_allow_senders").stringArray { it.isNotEmpty() }
            ?: return ParseResult.Rejected("sms_allow_senders is not an array of non-empty strings")

        return ParseResult.Ok(
            Blocklist(
                version = version,
                generatedAt = generatedAt,
                callNumbers = callNumbers.toSet(),
                callPrefixes = callPrefixes.toSet(),
            ),
        )
    }

    private fun decodeUtf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()

    /**
     * True if [text] opens more than [max] arrays/objects inside each other.
     * Brackets inside JSON strings (including after a backslash escape) are not
     * counted. Up to the first syntax error this count equals the parser's
     * recursion depth, and the parser stops at that error, so malformed text
     * cannot get past this check into deep recursion.
     */
    private fun exceedsDepth(text: String, max: Int): Boolean {
        var depth = 0
        var inString = false
        var escaped = false
        for (c in text) {
            when {
                escaped -> escaped = false
                inString -> when (c) {
                    '\\' -> escaped = true
                    '"' -> inString = false
                }
                c == '"' -> inString = true
                c == '[' || c == '{' -> if (++depth > max) return true
                c == ']' || c == '}' -> depth--
            }
        }
        return false
    }

    private fun isDateTime(s: String): Boolean {
        if (!GENERATED_AT.matches(s)) return false
        return try {
            OffsetDateTime.parse(s.uppercase(Locale.ROOT))
            true
        } catch (e: DateTimeParseException) {
            false
        }
    }

    private fun isKeywordArray(e: JsonElement): Boolean = e is JsonArray && e.all { kw ->
        kw is JsonObject &&
            kw.keys == KEYWORD_KEYS &&
            !kw.getValue("text").stringContent().isNullOrEmpty() &&
            when (kw.getValue("strength").stringContent()) {
                "strong", "weak" -> true
                else -> false
            }
    }

    /** The content of a JSON string, or null for any other element (including `null`). */
    private fun JsonElement.stringContent(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** The literal of a JSON integer, or null for strings, `null`, booleans and non-integers. */
    private fun JsonElement.integerContent(): String? = (this as? JsonPrimitive)
        ?.takeIf { it !is JsonNull && !it.isString && JSON_INTEGER.matches(it.content) }
        ?.content

    /** The strings of a JSON array whose items are all strings passing [valid], or null. */
    private inline fun JsonElement.stringArray(valid: (String) -> Boolean): List<String>? {
        if (this !is JsonArray) return null
        return map { item -> item.stringContent()?.takeIf(valid) ?: return null }
    }
}
