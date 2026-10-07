import java.nio.file.Files
import java.nio.file.StandardCopyOption

plugins {
    alias(libs.plugins.android.application)
}

// Endpoints are build-time configuration. The defaults are deliberately fake
// (.invalid); real endpoints are passed with -Psheket.blocklistUrl=... and
// -Psheket.reportUrl=... and are never committed.
val blocklistUrl = providers.gradleProperty("sheket.blocklistUrl")
    .getOrElse("https://blocklist.example.invalid/v1/blocklist.json")
val reportUrl = providers.gradleProperty("sheket.reportUrl")
    .getOrElse("https://report.example.invalid/v1/reports")

// Rejects non-HTTPS endpoints and returns the value as an escaped Java string literal.
fun httpsBuildConfigString(name: String, value: String): String {
    if (!value.startsWith("https://")) throw GradleException("$name must start with https://")
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}

// Repo-root contract/: read-only acceptance tests shared with iOS and backend.
val contractDir = rootProject.file("../contract")

android {
    namespace = "app.sheket"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.sheket"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        buildConfigField("String", "BLOCKLIST_URL", httpsBuildConfigString("sheket.blocklistUrl", blocklistUrl))
        buildConfigField("String", "REPORT_URL", httpsBuildConfigString("sheket.reportUrl", reportUrl))
    }

    buildFeatures {
        buildConfig = true
    }

    testOptions {
        unitTests.all {
            it.systemProperty("sheket.contractDir", contractDir.absolutePath)
            it.systemProperty("sheket.coreSrcDir", file("src/main/kotlin/app/sheket/core").absolutePath)
            // The UI resource tests read res/ and the manifest as text; declared as
            // inputs so a resource-only change re-runs them.
            it.systemProperty("sheket.mainSrcDir", file("src/main").absolutePath)
            it.inputs.dir(contractDir)
                .withPropertyName("contractDir")
                .withPathSensitivity(PathSensitivity.RELATIVE)
            it.inputs.dir(file("src/main/res"))
                .withPropertyName("mainResDir")
                .withPathSensitivity(PathSensitivity.RELATIVE)
            it.inputs.file(file("src/main/AndroidManifest.xml"))
                .withPropertyName("mainManifest")
                .withPathSensitivity(PathSensitivity.RELATIVE)
        }
    }
}

kotlin {
    jvmToolchain(17)
}

// Copies the seed blocklist into a generated assets directory so it ships in
// the APK. Only contract/seed-blocklist.json is read; nothing is written into contract/.
abstract class SeedAssetTask : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val seed: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.deleteRecursively()
        out.mkdirs()
        Files.copy(
            seed.get().asFile.toPath(),
            out.resolve("seed-blocklist.json").toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
    }
}

val copySeedBlocklist = tasks.register<SeedAssetTask>("copySeedBlocklist") {
    description = "Copies contract/seed-blocklist.json into generated assets."
    seed.set(rootProject.layout.projectDirectory.file("../contract/seed-blocklist.json"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copySeedBlocklist, SeedAssetTask::outputDir)
    }
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}
