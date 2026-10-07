package app.sheket.screening

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * The screening decision and the log codec are plain Kotlin (AC-2, AC-3), so
 * they stay unit-testable on the JVM. The Android-facing files in the package
 * (the service and the AtomicFile-backed log) are not checked.
 */
class ScreeningPureSourcesTest {

    private val androidImport = Regex("^\\s*import\\s+androidx?\\.")

    @Test
    fun pureScreeningSourcesImportNoAndroidPackages() {
        val coreDir = System.getProperty("sheket.coreSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.coreSrcDir is not set; run the tests through Gradle")
        val dir = File(File(coreDir).parentFile, "screening")

        val hits = listOf("ScreeningDecision.kt", "ScreenedCalls.kt").flatMap { name ->
            val f = File(dir, name)
            assertTrue("missing source ${f.path}", f.isFile)
            f.readLines().mapIndexedNotNull { i, line ->
                if (androidImport.containsMatchIn(line)) "${f.path}:${i + 1}: ${line.trim()}" else null
            }
        }
        if (hits.isNotEmpty()) fail("Android imports in pure screening sources:\n" + hits.joinToString("\n"))
    }
}
