package app.sheket.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.io.File

/**
 * Reads the shared, read-only files in the repo's `contract/` directory. The
 * directory comes from the `sheket.contractDir` system property set by Gradle;
 * paths are never resolved relative to the working directory, and nothing is
 * ever copied into `android/`.
 */
object ContractFiles {

    val dir: File by lazy {
        val path = System.getProperty("sheket.contractDir")
        if (path.isNullOrBlank()) {
            throw IllegalStateException("system property sheket.contractDir is not set; run the tests through Gradle")
        }
        val d = File(path)
        check(d.isAbsolute && d.isDirectory) { "sheket.contractDir is not an absolute directory: $path" }
        d
    }

    fun bytes(name: String): ByteArray {
        val f = File(dir, name)
        check(f.isFile) { "contract file not found: ${f.absolutePath}" }
        return f.readBytes()
    }

    fun json(name: String): JsonObject = Json.parseToJsonElement(bytes(name).toString(Charsets.UTF_8)) as? JsonObject
        ?: throw IllegalStateException("contract/$name is not a JSON object")

    /** A section of `corpus.json`; fails if it is missing or empty, so a test can never pass vacuously. */
    fun corpusSection(name: String): JsonArray {
        val section = json("corpus.json")[name] as? JsonArray
            ?: throw IllegalStateException("contract/corpus.json has no \"$name\" array")
        check(section.isNotEmpty()) { "contract/corpus.json \"$name\" is empty" }
        return section
    }
}
