package app.sheket.ui

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * The stale-line rule is plain Kotlin (AC-2), so it stays unit-testable on the
 * JVM. The activities in the package are Android-facing and are not checked.
 */
class StaleLinePureSourceTest {

    private val androidImport = Regex("^\\s*import\\s+androidx?\\.")

    @Test
    fun staleLineImportsNoAndroidPackages() {
        val coreDir = System.getProperty("sheket.coreSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.coreSrcDir is not set; run the tests through Gradle")
        val f = File(File(File(coreDir).parentFile, "ui"), "StaleLine.kt")
        assertTrue("missing source ${f.path}", f.isFile)

        val hits = f.readLines().mapIndexedNotNull { i, line ->
            if (androidImport.containsMatchIn(line)) "${f.path}:${i + 1}: ${line.trim()}" else null
        }
        if (hits.isNotEmpty()) fail("Android imports in StaleLine.kt:\n" + hits.joinToString("\n"))
    }
}
