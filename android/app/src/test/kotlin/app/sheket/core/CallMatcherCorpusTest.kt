package app.sheket.core

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
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
}
