package app.sheket.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.w3c.dom.Document
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Issue #46: `SheketApp.onCreate` schedules the refresh job on every process
 * start, and JobScheduler throws a SecurityException at launch when the job
 * uses a constraint whose permission the manifest does not declare. A JVM test
 * cannot call JobScheduler (the android.jar is stubbed), so this reads the job
 * builder in `RefreshJobService.kt` and the manifest from `src/main` (the
 * `sheket.mainSrcDir` system property) and checks they agree.
 */
class RefreshJobManifestTest {

    private val mainDir: File by lazy {
        val path = System.getProperty("sheket.mainSrcDir")?.takeIf { it.isNotBlank() }
            ?: throw AssertionError("system property sheket.mainSrcDir is not set; run the tests through Gradle")
        File(path).also { assertTrue("sheket.mainSrcDir is not a directory: $path", it.isDirectory) }
    }

    private val manifest: Document by lazy {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        factory.newDocumentBuilder().parse(File(mainDir, "AndroidManifest.xml"))
    }

    /** `uses-permission` names that are declared, not stripped with `tools:node="remove"`. */
    private val declaredPermissions: Set<String> by lazy {
        usesPermissions().filter { it.getAttributeNS(TOOLS_NS, "node") != "remove" }
            .map { it.getAttributeNS(ANDROID_NS, "name") }
            .toSet()
    }

    /** The job builder code, without comments, so a comment naming a permission cannot satisfy a check. */
    private val jobSource: String by lazy { kotlinSource("kotlin/app/sheket/data/RefreshJobService.kt") }

    @Test
    fun manifestDeclaresAccessNetworkState() {
        assertTrue(
            "AndroidManifest.xml must declare $ACCESS_NETWORK_STATE; declared: $declaredPermissions",
            ACCESS_NETWORK_STATE in declaredPermissions,
        )
    }

    @Test
    fun everyJobConstraintHasItsPermissionDeclared() {
        val used = CONSTRAINT_PERMISSIONS.filter { (call, _) -> call.containsMatchIn(jobSource) }
        // Guards the table itself: the network constraint must be found, or the
        // check below would pass vacuously after a rename or reformat.
        assertTrue(
            "no network constraint found in RefreshJobService.kt",
            used.any { it.second == ACCESS_NETWORK_STATE },
        )
        val missing = used.filter { (_, permission) -> permission !in declaredPermissions }
            .map { (call, permission) -> "${call.pattern} needs $permission" }
        if (missing.isNotEmpty()) {
            fail("job constraints whose permission AndroidManifest.xml lacks:\n" + missing.joinToString("\n"))
        }
    }

    @Test
    fun refreshJobKeepsItsNetworkConstraint() {
        // The fix is the permission, not dropping the constraint: the refresh must not run offline.
        val match = NETWORK_TYPE.find(jobSource)
        assertNotNull("RefreshJobService.kt must call setRequiredNetworkType(JobInfo.NETWORK_TYPE_...)", match)
        assertNotEquals("the network constraint must not be NETWORK_TYPE_NONE", "NONE", match!!.groupValues[1])
    }

    @Test
    fun readContactsStaysRemoved() {
        // Spec 4: contacts are never requested.
        assertTrue("READ_CONTACTS must not be declared", READ_CONTACTS !in declaredPermissions)
        val entries = usesPermissions().filter { it.getAttributeNS(ANDROID_NS, "name") == READ_CONTACTS }
        assertEquals("exactly one READ_CONTACTS entry, with tools:node=\"remove\"", 1, entries.size)
        assertEquals("remove", entries.single().getAttributeNS(TOOLS_NS, "node"))
    }

    @Test
    fun jobIsScheduledAtLaunchAndDeclaredAsAJobService() {
        // Why a missing permission crashes the app at launch rather than later.
        val app = elements("application").single()
        assertEquals(".SheketApp", app.getAttributeNS(ANDROID_NS, "name"))
        val onCreate = ON_CREATE.find(kotlinSource("kotlin/app/sheket/SheketApp.kt"))?.value
        assertNotNull("SheketApp.kt has no onCreate", onCreate)
        assertTrue("SheketApp.onCreate must schedule the refresh", "RefreshJobService.schedule(this)" in onCreate!!)

        val service = elements("service").singleOrNull { it.getAttributeNS(ANDROID_NS, "name") == ".data.RefreshJobService" }
        assertNotNull("RefreshJobService is not declared in the manifest", service)
        assertEquals("android.permission.BIND_JOB_SERVICE", service!!.getAttributeNS(ANDROID_NS, "permission"))
        assertEquals("false", service.getAttributeNS(ANDROID_NS, "exported"))
    }

    private fun usesPermissions(): List<Element> = elements("uses-permission")

    private fun elements(tag: String): List<Element> {
        val nodes = manifest.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun kotlinSource(relative: String): String {
        val file = File(mainDir, relative)
        assertTrue("missing source ${file.path}", file.isFile)
        return file.readText().replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        const val TOOLS_NS = "http://schemas.android.com/tools"
        const val ACCESS_NETWORK_STATE = "android.permission.ACCESS_NETWORK_STATE"
        const val READ_CONTACTS = "android.permission.READ_CONTACTS"

        /** JobInfo.Builder calls that JobScheduler rejects unless the app holds the paired permission. */
        val CONSTRAINT_PERMISSIONS = listOf(
            Regex("""\.setRequiredNetworkType\(\s*JobInfo\.NETWORK_TYPE_(?!NONE\b)""") to ACCESS_NETWORK_STATE,
            Regex("""\.setRequiredNetwork\(""") to ACCESS_NETWORK_STATE,
            Regex("""\.setPersisted\(\s*true\s*\)""") to "android.permission.RECEIVE_BOOT_COMPLETED",
        )

        val NETWORK_TYPE = Regex("""\.setRequiredNetworkType\(\s*JobInfo\.NETWORK_TYPE_(\w+)""")
        val ON_CREATE = Regex("""override fun onCreate\(\)\s*\{[^}]*}""")
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)
        val LINE_COMMENT = Regex("""//[^\n]*""")
    }
}
