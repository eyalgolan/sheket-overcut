package app.sheket.report

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * The install ID check (#24 AC-3, REQ-2). [InstallId.get] needs a real
 * `Context`, which JVM unit tests do not have, so these tests cover the pure
 * check it applies to stored values and the UUID form it creates.
 */
class InstallIdTest {

    @Test
    fun randomUuidsAreCanonical() {
        val ids = (1..1_000).map { UUID.randomUUID().toString() }
        for (id in ids) {
            assertEquals(36, id.length)
            assertTrue("not canonical: $id", InstallId.isCanonical(id))
        }
        // Random, so not tied to a person: no two installs share one.
        assertEquals(ids.size, ids.toSet().size)
        // Version 4 (random) UUIDs.
        assertTrue(ids.all { UUID.fromString(it).version() == 4 })
    }

    @Test
    fun canonicalFormIsAccepted() {
        assertTrue(InstallId.isCanonical("123e4567-e89b-42d3-a456-426614174000"))
        assertTrue(InstallId.isCanonical("00000000-0000-0000-0000-000000000000"))
    }

    @Test
    fun formsTheBackendRejectsAreNotCanonical() {
        val rejected = listOf(
            null,
            "",
            "123E4567-E89B-42D3-A456-426614174000", // uppercase: the backend lowercases, so it would not match
            "123e4567-e89b-42d3-a456-42661417400", // 35 characters
            "123e4567-e89b-42d3-a456-4266141740000", // 37 characters
            "123e4567e89b42d3a456426614174000", // no hyphens
            "{123e4567-e89b-42d3-a456-426614174000}", // braces
            "urn:uuid:123e4567-e89b-42d3-a456-426614174000",
            "123e4567-e89b-42d3-a456-42661417400g", // not hex
            "123e4567-e89b-42d3-a456-426614174000\n", // trailing newline: full match only
            " 123e4567-e89b-42d3-a456-426614174000",
            "123e4567-e89b42d3-a456-4266-14174000", // hyphens in the wrong places
        )
        for (s in rejected) {
            assertFalse("accepted: $s", InstallId.isCanonical(s))
        }
    }
}
