package app.sheket.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.w3c.dom.Document
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Static checks on the UI resources and manifest entries of #23 (AC-3, REQ-4)
 * and the report screen of #24 (REQ-5):
 * every user-visible string is a resource in both English and Hebrew, layouts
 * hold no hard-coded text, and the layouts are right-to-left safe. The files
 * are read as XML from `src/main` (the `sheket.mainSrcDir` system property),
 * since JVM unit tests have no merged Android resources.
 */
class UiResourcesTest {

    private val mainDir: File by lazy {
        val path = System.getProperty("sheket.mainSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.mainSrcDir is not set; run the tests through Gradle")
        File(path).also { assertTrue("sheket.mainSrcDir is not a directory: $path", it.isDirectory) }
    }
    private val resDir: File get() = File(mainDir, "res")

    private val english: Map<String, String> by lazy { strings(File(resDir, "values/strings.xml")) }
    private val hebrew: Map<String, String> by lazy { strings(File(resDir, "values-iw/strings.xml")) }

    private val layouts: List<File> by lazy {
        val dir = File(resDir, "layout")
        val files = dir.listFiles { f -> f.isFile && f.extension == "xml" }?.sortedBy { it.name }.orEmpty()
        assertTrue("no layouts under ${dir.path}", files.isNotEmpty())
        files
    }

    @Test
    fun bothScreensHaveLayouts() {
        val names = layouts.map { it.name }.toSet()
        assertTrue("missing activity_status.xml in $names", "activity_status.xml" in names)
        assertTrue("missing activity_about.xml in $names", "activity_about.xml" in names)
        assertTrue("missing activity_report.xml in $names", "activity_report.xml" in names)
        assertTrue("missing item_screened_call.xml in $names", "item_screened_call.xml" in names)
    }

    @Test
    fun reportLayoutsHaveTheViewsReportActivityUses() {
        val screen = viewsById(File(resDir, "layout/activity_report.xml"))
        assertEquals("ListView", screen["report_list"]?.tagName)
        assertEquals("TextView", screen["report_empty"]?.tagName)
        assertEquals("@string/report_empty", screen.getValue("report_empty").getAttributeNS(ANDROID_NS, "text"))
        assertEquals("TextView", screen["report_result"]?.tagName)
        // Shown only once there is a result, and the empty text only once the log is read.
        assertEquals("gone", screen.getValue("report_result").getAttributeNS(ANDROID_NS, "visibility"))
        assertEquals("gone", screen.getValue("report_empty").getAttributeNS(ANDROID_NS, "visibility"))

        val row = viewsById(File(resDir, "layout/item_screened_call.xml"))
        assertEquals("TextView", row["call_number"]?.tagName)
        assertEquals("TextView", row["call_detail"]?.tagName)
        assertEquals("Button", row["call_report"]?.tagName)
        assertEquals("@string/report_action", row.getValue("call_report").getAttributeNS(ANDROID_NS, "text"))
        assertEquals("ProgressBar", row["call_progress"]?.tagName)
        assertEquals("TextView", row["call_state"]?.tagName)
        // The end area starts hidden; the adapter shows exactly one of them per row.
        for (id in listOf("call_report", "call_progress", "call_state")) {
            assertEquals("$id visibility", "gone", row.getValue(id).getAttributeNS(ANDROID_NS, "visibility"))
        }
        // A focusable button inside a ListView row would take focus from the row.
        assertEquals("false", row.getValue("call_report").getAttributeNS(ANDROID_NS, "focusable"))
    }

    @Test
    fun statusScreenLinksToTheReportScreen() {
        val status = viewsById(File(resDir, "layout/activity_status.xml"))
        val button = status["report_button"]
        assertEquals("Button", button?.tagName)
        assertEquals("@string/report_button", button!!.getAttributeNS(ANDROID_NS, "text"))
    }

    @Test
    fun englishAndHebrewHaveTheSameKeys() {
        assertTrue("values/strings.xml is empty", english.isNotEmpty())
        assertEquals("keys only in values/", emptySet<String>(), english.keys - hebrew.keys)
        assertEquals("keys only in values-iw/", emptySet<String>(), hebrew.keys - english.keys)
    }

    @Test
    fun noStringIsBlank() {
        val blank = (english.map { "values/${it.key}" to it.value } + hebrew.map { "values-iw/${it.key}" to it.value })
            .filter { it.second.isBlank() }
            .map { it.first }
        assertEquals("blank strings", emptyList<String>(), blank)
    }

    @Test
    fun hebrewStringsAreTranslated() {
        val untranslated = hebrew.filterValues { !HEBREW_LETTER.containsMatchIn(it) }.keys
        assertEquals("values-iw strings with no Hebrew letters", emptySet<String>(), untranslated)
    }

    @Test
    fun formatArgumentsArePositionalAndMatchAcrossLocales() {
        val problems = mutableListOf<String>()
        for ((key, en) in english) {
            val enArgs = formatArgs(en)
            val heArgs = formatArgs(hebrew[key] ?: continue)
            if (enArgs != heArgs) problems += "$key: values/ has $enArgs, values-iw/ has $heArgs"
            (enArgs + heArgs).filterNot { POSITIONAL_ARG.matches(it) }.forEach {
                problems += "$key: non-positional format argument $it"
            }
        }
        if (problems.isNotEmpty()) fail(problems.joinToString("\n"))
    }

    @Test
    fun formatArgumentsUsedByStatusAndAboutScreens() {
        // StatusActivity and AboutActivity call getString with these argument types.
        val expected = mapOf(
            "list_generated_at" to listOf("%1\$s"),
            "list_counts" to listOf("%1\$d", "%2\$d"),
            "stale_last_updated" to listOf("%1\$s"),
            "blocked_last_7_days" to listOf("%1\$d"),
            "about_version" to listOf("%1\$s"),
        )
        for ((key, args) in expected) {
            assertEquals("values/$key", args, formatArgs(english.getValue(key)))
            assertEquals("values-iw/$key", args, formatArgs(hebrew.getValue(key)))
        }
    }

    @Test
    fun layoutsHaveNoHardCodedText() {
        val problems = mutableListOf<String>()
        for (file in layouts) {
            forEachElement(parse(file)) { el ->
                for (attr in TEXT_ATTRS) {
                    val v = el.getAttributeNS(ANDROID_NS, attr)
                    if (v.isNotEmpty() && !v.startsWith("@string/")) {
                        problems += "${file.name}: <${el.tagName}> android:$attr=\"$v\""
                    }
                }
                val toolsText = el.getAttributeNS(TOOLS_NS, "text")
                if (toolsText.isNotEmpty()) problems += "${file.name}: <${el.tagName}> tools:text=\"$toolsText\""
            }
        }
        if (problems.isNotEmpty()) fail("hard-coded UI text:\n" + problems.joinToString("\n"))
    }

    @Test
    fun manifestLabelsAreStringResources() {
        val problems = mutableListOf<String>()
        forEachElement(manifest()) { el ->
            val label = el.getAttributeNS(ANDROID_NS, "label")
            val hardCoded = label.isNotEmpty() && !label.startsWith("@string/")
            if (hardCoded) problems += "<${el.tagName}> android:label=\"$label\""
        }
        if (problems.isNotEmpty()) fail("hard-coded manifest labels:\n" + problems.joinToString("\n"))
    }

    @Test
    fun everyReferencedStringExists() {
        val missing = referencedStrings().filterNot { it.second in english }.map { "${it.first}: ${it.second}" }
        assertEquals("references to undefined strings", emptyList<String>(), missing)
    }

    @Test
    fun everyDefinedStringIsUsed() {
        val used = referencedStrings().map { it.second }.toSet()
        assertEquals("unused string resources", emptySet<String>(), english.keys - used)
    }

    @Test
    fun layoutsAreRightToLeftSafe() {
        val problems = mutableListOf<String>()
        for (file in layouts) {
            forEachElement(parse(file)) { el ->
                val attrs = el.attributes
                for (i in 0 until attrs.length) {
                    val a = attrs.item(i)
                    if (a.namespaceURI != ANDROID_NS) continue
                    val name = a.localName
                    if (name.contains("Left") || name.contains("Right")) {
                        problems += "${file.name}: <${el.tagName}> android:$name"
                    }
                    if ((name == "gravity" || name == "layout_gravity") && LEFT_RIGHT.containsMatchIn(a.nodeValue)) {
                        problems += "${file.name}: <${el.tagName}> android:$name=\"${a.nodeValue}\""
                    }
                }
            }
        }
        if (problems.isNotEmpty()) fail("left/right attributes break RTL:\n" + problems.joinToString("\n"))
    }

    @Test
    fun manifestDeclaresTheScreens() {
        val doc = manifest()
        val app = doc.getElementsByTagName("application").item(0) as Element
        assertEquals("true", app.getAttributeNS(ANDROID_NS, "supportsRtl"))
        assertEquals("@string/app_name", app.getAttributeNS(ANDROID_NS, "label"))
        assertEquals("@mipmap/ic_launcher", app.getAttributeNS(ANDROID_NS, "icon"))
        assertEquals("@style/Theme.Sheket", app.getAttributeNS(ANDROID_NS, "theme"))

        val activities = elements(doc, "activity").associateBy { it.getAttributeNS(ANDROID_NS, "name") }
        assertEquals(setOf(".ui.StatusActivity", ".ui.AboutActivity", ".ui.ReportActivity"), activities.keys)

        val status = activities.getValue(".ui.StatusActivity")
        assertEquals("StatusActivity must be exported", "true", status.getAttributeNS(ANDROID_NS, "exported"))
        val filters = elements(status, "intent-filter")
        assertTrue(
            "StatusActivity needs a MAIN/LAUNCHER intent filter",
            filters.any { f ->
                elements(f, "action").any { it.getAttributeNS(ANDROID_NS, "name") == "android.intent.action.MAIN" } &&
                    elements(f, "category").any {
                        it.getAttributeNS(ANDROID_NS, "name") == "android.intent.category.LAUNCHER"
                    }
            },
        )

        val about = activities.getValue(".ui.AboutActivity")
        assertEquals("AboutActivity must not be exported", "false", about.getAttributeNS(ANDROID_NS, "exported"))
        assertTrue("AboutActivity must have no intent filter", elements(about, "intent-filter").isEmpty())

        val report = activities.getValue(".ui.ReportActivity")
        assertEquals("ReportActivity must not be exported", "false", report.getAttributeNS(ANDROID_NS, "exported"))
        assertTrue("ReportActivity must have no intent filter", elements(report, "intent-filter").isEmpty())
        assertEquals("@string/report_title", report.getAttributeNS(ANDROID_NS, "label"))
    }

    @Test
    fun reportStringsTakeNoArguments() {
        // ReportActivity calls getString and setText on these without arguments.
        val reportKeys = english.keys.filter { it.startsWith("report_") }
        assertTrue("no report_ strings", reportKeys.size >= 12)
        for (key in reportKeys) {
            assertEquals("values/$key", emptyList<String>(), formatArgs(english.getValue(key)))
            assertEquals("values-iw/$key", emptyList<String>(), formatArgs(hebrew.getValue(key)))
        }
    }

    @Test
    fun themeIsFrameworkDayNight() {
        val doc = parse(File(resDir, "values/themes.xml"))
        val theme = elements(doc, "style").single { it.getAttribute("name") == "Theme.Sheket" }
        assertEquals("@android:style/Theme.DeviceDefault.DayNight", theme.getAttribute("parent"))
    }

    @Test
    fun launcherIconIsAdaptiveVector() {
        val icon = parse(File(resDir, "mipmap-anydpi/ic_launcher.xml"))
        assertEquals("adaptive-icon", icon.documentElement.tagName)
        for (part in listOf("background", "foreground")) {
            val el = elements(icon, part).single()
            val ref = el.getAttributeNS(ANDROID_NS, "drawable")
            assertTrue("$part must be a drawable reference: $ref", ref.startsWith("@drawable/"))
            val drawable = parse(File(resDir, "drawable/${ref.removePrefix("@drawable/")}.xml"))
            assertEquals("$part drawable must be a vector", "vector", drawable.documentElement.tagName)
        }
    }

    /** `@string/x` references in res/ and the manifest, and `R.string.x` in the Kotlin sources. */
    private fun referencedStrings(): List<Pair<String, String>> {
        val xmlRef = Regex("@string/([A-Za-z0-9_]+)")
        val codeRef = Regex("\\bR\\.string\\.([A-Za-z0-9_]+)")
        val xmlFiles = resDir.walkTopDown()
            .filter { it.isFile && it.extension == "xml" && !it.parentFile.name.startsWith("values") }
            .plus(File(mainDir, "AndroidManifest.xml"))
        val codeFiles = File(mainDir, "kotlin").walkTopDown().filter { it.isFile && it.extension == "kt" }
        return xmlFiles.flatMap { f -> xmlRef.findAll(f.readText()).map { f.name to it.groupValues[1] } }.toList() +
            codeFiles.flatMap { f -> codeRef.findAll(f.readText()).map { f.name to it.groupValues[1] } }.toList()
    }

    /** The elements of [file] that have an `android:id`, keyed by the id name. */
    private fun viewsById(file: File): Map<String, Element> {
        val result = linkedMapOf<String, Element>()
        forEachElement(parse(file)) { el ->
            val id = el.getAttributeNS(ANDROID_NS, "id")
            if (id.startsWith("@+id/")) result[id.removePrefix("@+id/")] = el
        }
        return result
    }

    private fun strings(file: File): Map<String, String> {
        assertTrue("missing ${file.path}", file.isFile)
        val result = linkedMapOf<String, String>()
        for (el in elements(parse(file), "string")) {
            val name = el.getAttribute("name")
            assertTrue("duplicate string $name in ${file.path}", result.put(name, el.textContent) == null)
        }
        return result
    }

    private fun formatArgs(s: String): List<String> =
        FORMAT_ARG.findAll(s).map { it.value }.filter { it != "%%" }.toList()

    private fun manifest(): Document = parse(File(mainDir, "AndroidManifest.xml"))

    private fun parse(file: File): Document {
        assertTrue("missing ${file.path}", file.isFile)
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        return factory.newDocumentBuilder().parse(file)
    }

    private fun elements(doc: Document, tag: String): List<Element> = doc.documentElement.let { elements(it, tag) }

    private fun elements(parent: Element, tag: String): List<Element> {
        val nodes = parent.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun forEachElement(doc: Document, action: (Element) -> Unit) {
        val nodes = doc.getElementsByTagName("*")
        for (i in 0 until nodes.length) action(nodes.item(i) as Element)
    }

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        const val TOOLS_NS = "http://schemas.android.com/tools"
        val TEXT_ATTRS = listOf("text", "hint", "contentDescription", "title", "label", "prompt")
        val HEBREW_LETTER = Regex("[\\u05D0-\\u05EA]")
        val FORMAT_ARG = Regex("%(?:\\d+\\$)?[-#+ 0,(]*\\d*(?:\\.\\d+)?[a-zA-Z%]")
        val POSITIONAL_ARG = Regex("%\\d+\\$[a-zA-Z]")
        val LEFT_RIGHT = Regex("\\b(left|right)\\b")
    }
}
