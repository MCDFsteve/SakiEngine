package dev.aimesoft.erika_flutter

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AndroidContentSourceTest {
    @Test
    fun `regular descriptor with trusted stat size keeps the owned fd zero copy path`() {
        assertEquals(
            AndroidContentTransport.OWNED_DESCRIPTOR,
            androidContentTransport(AndroidContentDescriptorKind.REGULAR_FILE, statSize = 42L),
        )
    }

    @Test
    fun `non regular or unstatable descriptors always spool`() {
        assertEquals(
            AndroidContentTransport.CACHE_SPOOL,
            androidContentTransport(AndroidContentDescriptorKind.FIFO, statSize = 0L),
        )
        assertEquals(
            AndroidContentTransport.CACHE_SPOOL,
            androidContentTransport(AndroidContentDescriptorKind.SOCKET, statSize = 4096L),
        )
        assertEquals(
            AndroidContentTransport.CACHE_SPOOL,
            androidContentTransport(AndroidContentDescriptorKind.REGULAR_FILE, statSize = null),
        )
    }

    @Test
    fun `descriptor fallback reasons are structured and specific`() {
        assertEquals(
            "fifo_descriptor",
            androidContentFallbackReason(AndroidContentDescriptorKind.FIFO),
        )
        assertEquals(
            "descriptor_stat_unavailable",
            androidContentFallbackReason(AndroidContentDescriptorKind.UNKNOWN),
        )
    }

    @Test
    fun `spooler streams every byte and validates declared length`() {
        val source = ByteArray(900_000) { index -> (index * 31).toByte() }
        val destination = ByteArrayOutputStream()

        val copied = AndroidContentSpooler.copy(
            ByteArrayInputStream(source),
            destination,
            expectedLength = source.size.toLong(),
        )

        assertEquals(source.size.toLong(), copied)
        assertArrayEquals(source, destination.toByteArray())
    }

    @Test(expected = EOFException::class)
    fun `spooler rejects an empty provider stream`() {
        AndroidContentSpooler.copy(
            ByteArrayInputStream(byteArrayOf()),
            ByteArrayOutputStream(),
            expectedLength = null,
        )
    }

    @Test(expected = EOFException::class)
    fun `spooler rejects a provider stream shorter than declared`() {
        AndroidContentSpooler.copy(
            ByteArrayInputStream(byteArrayOf(1, 2, 3)),
            ByteArrayOutputStream(),
            expectedLength = 4L,
        )
    }

    @Test(expected = IOException::class)
    fun `spooler rejects a provider stream longer than declared`() {
        AndroidContentSpooler.copy(
            ByteArrayInputStream(byteArrayOf(1, 2, 3)),
            ByteArrayOutputStream(),
            expectedLength = 2L,
        )
    }

    @Test
    fun `spooler enforces the configured maximum before accepting an oversized source`() {
        val error = try {
            AndroidContentSpooler.copy(
                ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)),
                ByteArrayOutputStream(),
                expectedLength = null,
                policy = AndroidContentSpoolPolicy(maxBytes = 3L, minFreeBytes = 0L),
            )
            fail("expected max-byte rejection")
            null
        } catch (error: AndroidContentSpoolException) {
            error
        }

        assertEquals("max_bytes_exceeded", error?.reasonCode)
    }

    @Test
    fun `spooler preserves the configured free disk budget`() {
        val error = try {
            AndroidContentSpooler.copy(
                ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)),
                ByteArrayOutputStream(),
                expectedLength = 4L,
                policy = AndroidContentSpoolPolicy(maxBytes = 10L, minFreeBytes = 2L),
                availableBytes = { 5L },
            )
            fail("expected disk-budget rejection")
            null
        } catch (error: AndroidContentSpoolException) {
            error
        }

        assertEquals("insufficient_disk_budget", error?.reasonCode)
    }

    @Test
    fun `spool cancellation is observed between bounded copy chunks`() {
        val source = ByteArray(600_000) { 7 }
        var cancel = false
        val error = try {
            AndroidContentSpooler.copy(
                ByteArrayInputStream(source),
                ByteArrayOutputStream(),
                expectedLength = null,
                policy = AndroidContentSpoolPolicy(
                    maxBytes = source.size.toLong(),
                    minFreeBytes = 0L,
                ),
                cancelled = { cancel },
                onProgress = { cancel = true },
            )
            fail("expected cancellation")
            null
        } catch (error: AndroidContentPreparationCancelledException) {
            error
        }

        assertEquals("cancelled", androidContentSourceFailureReason(checkNotNull(error)))
    }

    @Test
    fun `cancelling a preparation closes provider resources and deletes its temp file`() {
        val cancellation = AndroidContentPreparationCancellation()
        var closed = false
        val resource = Closeable { closed = true }
        val temporaryFile = File.createTempFile("erika-content-test-", ".tmp")
        cancellation.register(resource)
        cancellation.trackTemporaryFile(temporaryFile)

        cancellation.cancel()

        assertTrue(closed)
        assertFalse(temporaryFile.exists())
        assertTrue(cancellation.isCancelled)
    }

    @Test
    fun `invalidating a player preparation generation cancels and rejects stale completion`() {
        val registry = AndroidContentPreparationRegistry()
        val cancellationReasons = mutableListOf<String>()
        val first = registry.begin(cancellationReasons::add)
        val second = registry.begin(cancellationReasons::add)

        assertEquals(2, registry.invalidate("superseded_by_open"))

        assertEquals(listOf("superseded_by_open", "superseded_by_open"), cancellationReasons)
        assertEquals(0, registry.pendingCount)
        assertFalse(registry.finish(first))
        assertFalse(registry.finish(second))
    }

    @Test
    fun `startup scavenger accepts only Erika source temp file names`() {
        assertTrue(isAndroidContentSpoolFileName("source-123.tmp"))
        assertTrue(isAndroidContentSpoolFileName("source-provider-cache.tmp"))
        assertFalse(isAndroidContentSpoolFileName("source-.tmp"))
        assertFalse(isAndroidContentSpoolFileName("source-123.part"))
        assertFalse(isAndroidContentSpoolFileName("other-source-123.tmp"))
        assertFalse(isAndroidContentSpoolFileName("SOURCE-123.tmp"))
    }

    @Test
    fun `startup scavenger deletes only matching files and reports reclaimed bytes`() {
        val directory = Files.createTempDirectory("erika-content-scavenge-").toFile()
        try {
            val deleted = File(directory, "source-delete.tmp").apply {
                writeBytes(byteArrayOf(1, 2, 3))
            }
            val failed = File(directory, "source-fail.tmp").apply {
                writeBytes(byteArrayOf(4, 5, 6, 7))
            }
            val unrelated = File(directory, "unrelated.tmp").apply {
                writeBytes(byteArrayOf(8, 9))
            }
            val matchingDirectory = File(directory, "source-directory.tmp").apply {
                assertTrue(mkdir())
            }

            val stats = scavengeAndroidContentSpoolDirectory(directory) { file ->
                if (file == failed) false else deleteContentSpoolFile(file)
            }

            assertEquals(1, stats.files)
            assertEquals(3L, stats.bytes)
            assertEquals(1, stats.deleteFailures)
            assertFalse(deleted.exists())
            assertTrue(failed.exists())
            assertTrue(unrelated.exists())
            assertTrue(matchingDirectory.isDirectory)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `structured content log escapes provider data`() {
        val event = androidContentSourceEvent(
            stage = "fallback",
            authority = "provider\"name",
            fields = linkedMapOf(
                "reason" to "pipe\nsource",
                "length" to null,
                "retained" to false,
            ),
        )

        assertTrue(event.startsWith("{\"event\":\"android_content_source\""))
        assertTrue(event.contains("\"authority\":\"provider\\\"name\""))
        assertTrue(event.contains("\"reason\":\"pipe\\nsource\""))
        assertTrue(event.contains("\"length\":null"))
        assertTrue(event.contains("\"retained\":false"))
    }
}
