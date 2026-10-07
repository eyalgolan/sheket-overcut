package app.sheket.core

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** The matching core is plain Kotlin, so it can be unit-tested on the JVM without Android. */
class CoreHasNoAndroidImportsTest {

    private val androidImport = Regex("^\\s*import\\s+androidx?\\.")

    @Test
    fun coreSourcesImportNoAndroidPackages() {
        val path = System.getProperty("sheket.coreSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.coreSrcDir is not set; run the tests through Gradle")
        val dir = File(path)
        assertTrue("sheket.coreSrcDir is not a directory: $path", dir.isDirectory)

        val sources = dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("no .kt files under $path", sources.isNotEmpty())

        val hits = sources.flatMap { f ->
            f.readLines().mapIndexedNotNull { i, line ->
                if (androidImport.containsMatchIn(line)) "${f.path}:${i + 1}: ${line.trim()}" else null
            }
        }
        if (hits.isNotEmpty()) fail("Android imports in app.sheket.core:\n" + hits.joinToString("\n"))
    }
}
