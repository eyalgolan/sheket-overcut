package app.sheket.report

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * The report HTTP and outcome logic is plain Kotlin (#24 technical notes):
 * `android.util.Log` is a stub on the JVM, so logging stays in the caller.
 * `InstallId.kt` needs a `Context` and is not checked.
 */
class ReportPureSourcesTest {

    private val androidImport = Regex("^\\s*import\\s+androidx?\\.")

    @Test
    fun reportClientImportsNoAndroidPackages() {
        val coreDir = System.getProperty("sheket.coreSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.coreSrcDir is not set; run the tests through Gradle")
        val f = File(File(File(coreDir).parentFile, "report"), "ReportClient.kt")
        assertTrue("missing source ${f.path}", f.isFile)

        val hits = f.readLines().mapIndexedNotNull { i, line ->
            if (androidImport.containsMatchIn(line)) "${f.path}:${i + 1}: ${line.trim()}" else null
        }
        if (hits.isNotEmpty()) fail("Android imports in ReportClient.kt:\n" + hits.joinToString("\n"))
    }
}
