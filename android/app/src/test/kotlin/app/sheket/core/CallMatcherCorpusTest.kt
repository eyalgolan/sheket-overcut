package app.sheket.core

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Runs the `calls` cases of `contract/corpus.json` against
 * `contract/test-blocklist.json`.
 *
 * The `sms` cases are skipped on purpose: SMS filtering is cut from Android v1
 * (OQ-1 on #20/#16), so there is no SMS classifier to run them against. This
 * is in tension with `contract/README.md` ("The corpus runs against the seed
 * list in every track's tests") and spec section 11 (one shared corpus on both
 * platforms). If the owner answers OQ-1 "yes", running them becomes a
 * follow-up ticket.
 */
class CallMatcherCorpusTest {

    @Test
    fun corpusCallCases() {
        val parsed = BlocklistParser.parse(ContractFiles.bytes("test-blocklist.json"))
        assertTrue("test-blocklist.json must parse: $parsed", parsed is ParseResult.Ok)
        val matcher = CallMatcher((parsed as ParseResult.Ok).blocklist)

        val cases = ContractFiles.corpusSection("calls")
        assertEquals("number of calls cases", 12, cases.size)
        val failures = cases.mapNotNull { case ->
            val c = case.jsonObject
            val number = c.getValue("number").jsonPrimitive.content
            val expect = c.getValue("expect").jsonPrimitive.content
            assertTrue("unknown expect \"$expect\" for \"$number\"", expect == "block" || expect == "allow")
            val blocked = matcher.shouldBlock(number)
            if (blocked == (expect == "block")) {
                null
            } else {
                "shouldBlock(\"$number\"): expected $expect, got ${if (blocked) "block" else "allow"}" +
                    " (${c["why"]?.jsonPrimitive?.content})"
            }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size} calls case(s) failed:\n" + failures.joinToString("\n"))
        }
    }

    private fun testListMatcher(): CallMatcher {
        val parsed = BlocklistParser.parse(ContractFiles.bytes("test-blocklist.json"))
        assertTrue("test-blocklist.json must parse: $parsed", parsed is ParseResult.Ok)
        return CallMatcher((parsed as ParseResult.Ok).blocklist)
    }

    @Test
    fun secondTestPrefixBlocks() {
        // No corpus case exercises the +9725552 prefix of test-blocklist.json.
        val matcher = testListMatcher()
        assertTrue(matcher.shouldBlock("055-521-2345"))
        assertTrue(matcher.shouldBlock("+972555212345"))
        assertFalse(matcher.shouldBlock("0555312345"))
    }

    @Test
    fun nonE164CallersAreNeverBlocked() {
        val matcher = testListMatcher()
        val never = listOf(
            null,
            "",
            "Unknown",
            "100",
            "*6000",
            "tel:0555001234",
            "00972555001234",
            "٠٥٥٥٠٠١٢٣٤",
        )
        val blocked = never.filter { matcher.shouldBlock(it) }
        assertTrue("blocked non-E.164 callers: $blocked", blocked.isEmpty())
    }

    @Test
    fun prefixLengthsFiveToFifteenAreChecked() {
        val list = Blocklist(
            version = 1,
            generatedAt = "2026-10-06T12:00:00Z",
            callNumbers = emptySet(),
            callPrefixes = setOf("+1234", "+98765432109876", "+972"),
        )
        val matcher = CallMatcher(list)
        assertTrue("shortest valid prefix (5 chars)", matcher.shouldBlock("+12345678"))
        assertTrue("longest valid prefix (15 chars) equal to the number", matcher.shouldBlock("+98765432109876"))
        // A 4-character entry cannot pass the schema, so the matcher never looks at it.
        assertFalse(matcher.shouldBlock("+972555001234"))
        assertFalse(matcher.shouldBlock("+1235678"))
    }
}
