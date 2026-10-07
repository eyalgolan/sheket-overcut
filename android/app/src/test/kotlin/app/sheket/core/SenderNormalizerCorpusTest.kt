package app.sheket.core

import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class SenderNormalizerCorpusTest {

    @Test
    fun corpusNormalizeCases() {
        val cases = ContractFiles.corpusSection("normalize")
        assertEquals("number of normalize cases", 18, cases.size)
        val failures = cases.mapNotNull { case ->
            val c = case.jsonObject
            val input = c.getValue("in").jsonPrimitive.content
            val expected = c.getValue("out").jsonPrimitive.contentOrNull
            val actual = SenderNormalizer.normalize(input)
            if (actual == expected) null else "normalize(\"$input\"): expected $expected, got $actual"
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size} normalize case(s) failed:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun trimsNelAndFileSeparatorLikePythonIsspace() {
        assertEquals("+972555001234", SenderNormalizer.normalize("\u00850555001234\u001c"))
    }

    @Test
    fun trailingNewlineIsTrimmed() {
        assertEquals("+972555001234", SenderNormalizer.normalize("0555001234\n"))
    }

    @Test
    fun whitespaceIsExactlyPythonIsspace() {
        val expected = setOf(
            '\u0009', '\u000A', '\u000B', '\u000C', '\u000D',
            '\u001C', '\u001D', '\u001E', '\u001F',
            '\u0020', '\u0085', '\u00A0', '\u1680',
            '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
            '\u2006', '\u2007', '\u2008', '\u2009', '\u200A',
            '\u2028', '\u2029', '\u202F', '\u205F', '\u3000',
        )
        assertEquals(29, expected.size)
        assertEquals(expected, SenderNormalizer.WHITESPACE)
    }
}
