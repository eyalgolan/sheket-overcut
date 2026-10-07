package app.sheket.ui

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Whether a number is reported has one definition,
 * `ScreenedCallCodec.reportedNumbers` (#57). The per-entry `reported` flag
 * covers only the entries that existed when the report was accepted, so a row
 * state or a refusal decided from it would offer a Report button the client
 * then silently refuses. `ReportActivity` needs Android types and cannot run on
 * the JVM, so this checks the sources: outside the codec, no code reads the
 * flag, and the report screen uses the shared rule.
 */
class ReportedByNumberSourceTest {

    private val flagRead = Regex("""[\w)\]]\s*\.\s*reported\b""")

    private fun mainKotlinDir(): File {
        val coreDir = System.getProperty("sheket.coreSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.coreSrcDir is not set; run the tests through Gradle")
        return checkNotNull(File(coreDir).parentFile) { "no parent for $coreDir" }
    }

    private fun isComment(line: String): Boolean {
        val t = line.trim()
        return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
    }

    @Test
    fun onlyTheCodecReadsThePerEntryReportedFlag() {
        val dir = mainKotlinDir()
        val codec = File(File(dir, "screening"), "ScreenedCalls.kt")
        assertTrue("missing source ${codec.path}", codec.isFile)

        val sources = dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("no Kotlin sources under ${dir.path}", sources.size > 1)

        val hits = sources.filter { it.canonicalFile != codec.canonicalFile }.flatMap { f ->
            f.readLines().mapIndexedNotNull { i, line ->
                if (!isComment(line) && flagRead.containsMatchIn(line)) "${f.path}:${i + 1}: ${line.trim()}" else null
            }
        }
        if (hits.isNotEmpty()) {
            val rule = "Decide reported by number with ScreenedCallCodec.reportedNumbers, not the entry flag"
            fail("$rule:\n" + hits.joinToString("\n"))
        }
    }

    @Test
    fun reportScreenDecidesTheRowStateByNumber() {
        val f = File(File(mainKotlinDir(), "ui"), "ReportActivity.kt")
        assertTrue("missing source ${f.path}", f.isFile)
        val code = f.readLines().filterNot(::isComment).joinToString("\n")

        val rowRule = Regex(
            """\bentry\.number\s+in\s+reportedNumbers\s*->\s*showState\(row,\s*R\.string\.report_state_reported\)""",
        )
        assertTrue("ReportActivity must use the shared rule", "ScreenedCallCodec.reportedNumbers(" in code)
        assertTrue("the Reported row state must be decided by the entry's number", rowRule.containsMatchIn(code))
    }
}
