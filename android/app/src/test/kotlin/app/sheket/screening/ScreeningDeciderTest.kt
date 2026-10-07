package app.sheket.screening

import app.sheket.core.BlocklistParser
import app.sheket.core.CallMatcher
import app.sheket.core.ContractFiles
import app.sheket.core.ParseResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The handle-to-decision path of [SheketScreeningService] (AC-3, AC-4), tested
 * through the pure [ScreeningDecider] against `contract/test-blocklist.json`.
 */
class ScreeningDeciderTest {

    private val testMatcher: CallMatcher by lazy {
        val result = BlocklistParser.parse(ContractFiles.bytes("test-blocklist.json"))
        CallMatcher((result as ParseResult.Ok).blocklist)
    }

    private fun decide(scheme: String?, schemeSpecificPart: String?): ScreeningDecision =
        ScreeningDecider.decide(scheme, schemeSpecificPart) { testMatcher }

    // --- AC-3: tel: handles against test-blocklist.json ---

    @Test
    fun telNumberInCallNumbersBlocks() {
        assertEquals(ScreeningDecision(block = true, number = "+972555001234"), decide("tel", "+972555001234"))
    }

    @Test
    fun telLocalNumberUnderACallPrefixBlocks() {
        // 0555010000 normalises to +972555010000, which starts with the prefix +97255501.
        assertEquals(ScreeningDecision(block = true, number = "+972555010000"), decide("tel", "0555010000"))
    }

    @Test
    fun telLocalFormOfAListedNumberBlocks() {
        assertEquals(ScreeningDecision(block = true, number = "+972555001234"), decide("tel", "0555001234"))
    }

    @Test
    fun telNumberNotOnTheListIsAllowedButItsNumberIsRecorded() {
        assertEquals(ScreeningDecision(block = false, number = "+972555000001"), decide("tel", "+972555000001"))
    }

    @Test
    fun telSchemeIsMatchedCaseInsensitively() {
        assertTrue(decide("TEL", "+972555001234").block)
    }

    // --- AC-3: handles that allow ---

    @Test
    fun sipHandleAllowsWithoutConsultingTheMatcher() {
        var consulted = false
        val decision = ScreeningDecider.decide("sip", "+972555001234@example.invalid") {
            consulted = true
            testMatcher
        }
        assertSame(ScreeningDecision.ALLOW, decision)
        assertFalse(consulted)
    }

    @Test
    fun sipHandleWithAListedNumberAsUserPartAllows() {
        assertSame(ScreeningDecision.ALLOW, decide("sip", "+972555001234"))
    }

    @Test
    fun nullHandleAllows() {
        assertSame(ScreeningDecision.ALLOW, decide(null, null))
    }

    @Test
    fun nullSchemeWithANumberAllows() {
        assertSame(ScreeningDecision.ALLOW, decide(null, "+972555001234"))
    }

    @Test
    fun withheldTelCallerAllows() {
        assertSame(ScreeningDecision.ALLOW, decide("tel", null))
    }

    @Test
    fun telUnknownAllowsWithNoNumber() {
        assertEquals(ScreeningDecision(block = false, number = null), decide("tel", "Unknown"))
    }

    @Test
    fun telEmptyAllowsWithNoNumber() {
        assertEquals(ScreeningDecision(block = false, number = null), decide("tel", ""))
    }

    @Test
    fun otherSchemesAllow() {
        for (scheme in listOf("voicemail", "mailto", "", "tel:")) {
            assertSame("scheme '$scheme'", ScreeningDecision.ALLOW, decide(scheme, "+972555001234"))
        }
    }

    @Test
    fun theTelPrefixMustBeStrippedBeforeDeciding() {
        // The scheme-specific part never contains "tel:"; if it did, the normaliser would
        // treat it as a sender ID, so it neither blocks nor records a number.
        assertEquals(ScreeningDecision(block = false, number = null), decide("tel", "tel:+972555001234"))
    }

    // --- AC-4: any failure allows the call ---

    @Test
    fun supplierThatThrowsAllows() {
        val decision = ScreeningDecider.decide("tel", "+972555001234") { throw IllegalStateException("load failed") }
        assertSame(ScreeningDecision.ALLOW, decision)
    }

    @Test
    fun supplierThatThrowsAnErrorAllows() {
        val decision = ScreeningDecider.decide("tel", "+972555001234") { throw StackOverflowError() }
        assertSame(ScreeningDecision.ALLOW, decision)
    }

    @Test
    fun allowConstantBlocksNothingAndRecordsNoNumber() {
        assertFalse(ScreeningDecision.ALLOW.block)
        assertNull(ScreeningDecision.ALLOW.number)
    }
}
