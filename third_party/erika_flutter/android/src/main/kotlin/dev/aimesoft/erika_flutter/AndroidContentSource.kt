package dev.aimesoft.erika_flutter

import java.io.EOFException
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Future

internal const val ANDROID_CONTENT_SPOOL_MAX_BYTES = 8L * 1024L * 1024L * 1024L
internal const val ANDROID_CONTENT_SPOOL_MIN_FREE_BYTES = 128L * 1024L * 1024L
internal const val ANDROID_CONTENT_SPOOL_DIRECTORY = "erika-content-spool"
internal const val ANDROID_CONTENT_SPOOL_PREFIX = "source-"
internal const val ANDROID_CONTENT_SPOOL_SUFFIX = ".tmp"

internal data class AndroidContentSpoolScavengeStats(
    val files: Int,
    val bytes: Long,
    val deleteFailures: Int,
)

internal fun isAndroidContentSpoolFileName(name: String): Boolean =
    name.startsWith(ANDROID_CONTENT_SPOOL_PREFIX) &&
        name.endsWith(ANDROID_CONTENT_SPOOL_SUFFIX) &&
        name.length > ANDROID_CONTENT_SPOOL_PREFIX.length + ANDROID_CONTENT_SPOOL_SUFFIX.length

/** Deletes only cache files created by File.createTempFile for Android content spooling. */
internal fun scavengeAndroidContentSpoolDirectory(
    directory: File,
    deleteFile: (File) -> Boolean = ::deleteContentSpoolFile,
): AndroidContentSpoolScavengeStats {
    var deletedFiles = 0
    var deletedBytes = 0L
    var deleteFailures = 0
    directory.listFiles().orEmpty().forEach { file ->
        if (!file.isFile || !isAndroidContentSpoolFileName(file.name)) {
            return@forEach
        }
        val length = file.length().coerceAtLeast(0L)
        val deleted = runCatching { deleteFile(file) }.getOrDefault(false)
        if (deleted) {
            deletedFiles += 1
            deletedBytes = saturatedByteCount(deletedBytes, length)
        } else {
            deleteFailures += 1
        }
    }
    return AndroidContentSpoolScavengeStats(
        files = deletedFiles,
        bytes = deletedBytes,
        deleteFailures = deleteFailures,
    )
}

private fun saturatedByteCount(current: Long, additional: Long): Long =
    if (additional > Long.MAX_VALUE - current) Long.MAX_VALUE else current + additional

internal data class AndroidContentSpoolPolicy(
    val maxBytes: Long = ANDROID_CONTENT_SPOOL_MAX_BYTES,
    val minFreeBytes: Long = ANDROID_CONTENT_SPOOL_MIN_FREE_BYTES,
) {
    init {
        require(maxBytes > 0L) { "maxBytes must be positive" }
        require(minFreeBytes >= 0L) { "minFreeBytes must be non-negative" }
    }
}

internal class AndroidContentSpoolException(
    val reasonCode: String,
    message: String,
) : IOException(message)

internal fun androidContentSourceFailureReason(error: Throwable): String = when (error) {
    is AndroidContentSpoolException -> error.reasonCode
    is AndroidContentPreparationCancelledException -> "cancelled"
    is EOFException -> "provider_eof"
    else -> "io_failure"
}

internal class AndroidContentPreparationCancelledException(message: String) : IOException(message)

/**
 * Cross-thread cancellation for one content-provider preparation.
 *
 * Closing the registered provider stream wakes a worker blocked in a pipe read.
 * Tracked temporary files are unlinked immediately on cancellation and again by
 * the worker's `finally` path, so a late or uninterruptible provider cannot leave
 * a named cache entry behind.
 */
internal class AndroidContentPreparationCancellation {
    private val monitor = Any()
    private var cancelled = false
    private var future: Future<*>? = null
    private val closeables = linkedSetOf<Closeable>()
    private val temporaryFiles = linkedSetOf<File>()

    val isCancelled: Boolean
        get() = synchronized(monitor) { cancelled }

    fun attachFuture(value: Future<*>) {
        val cancelImmediately = synchronized(monitor) {
            if (cancelled) {
                true
            } else {
                future = value
                false
            }
        }
        if (cancelImmediately) {
            value.cancel(true)
        }
    }

    fun register(closeable: Closeable) {
        val closeImmediately = synchronized(monitor) {
            if (cancelled) {
                true
            } else {
                closeables.add(closeable)
                false
            }
        }
        if (closeImmediately) {
            runCatching(closeable::close)
            throw AndroidContentPreparationCancelledException(
                "Android content preparation was cancelled before the provider stream opened",
            )
        }
    }

    fun unregister(closeable: Closeable) {
        synchronized(monitor) { closeables.remove(closeable) }
    }

    fun trackTemporaryFile(file: File) {
        val deleteImmediately = synchronized(monitor) {
            if (cancelled) {
                true
            } else {
                temporaryFiles.add(file)
                false
            }
        }
        if (deleteImmediately) {
            deleteContentSpoolFile(file)
            throw AndroidContentPreparationCancelledException(
                "Android content preparation was cancelled before cache spooling started",
            )
        }
    }

    fun releaseTemporaryFile(file: File) {
        synchronized(monitor) { temporaryFiles.remove(file) }
    }

    fun throwIfCancelled() {
        if (isCancelled || Thread.currentThread().isInterrupted) {
            throw AndroidContentPreparationCancelledException(
                "Android content preparation was cancelled",
            )
        }
    }

    fun cancel() {
        val resources: List<Closeable>
        val files: List<File>
        val task: Future<*>?
        synchronized(monitor) {
            if (cancelled) {
                return
            }
            cancelled = true
            resources = closeables.toList()
            closeables.clear()
            files = temporaryFiles.toList()
            temporaryFiles.clear()
            task = future
            future = null
        }
        resources.forEach { closeable -> runCatching(closeable::close) }
        files.forEach(::deleteContentSpoolFile)
        task?.cancel(true)
    }
}

internal data class AndroidContentPreparationToken(
    val generation: Long,
    val commandId: Long,
)

/** Main-thread registry that prevents a late FD handoff from overtaking open/close/dispose. */
internal class AndroidContentPreparationRegistry {
    private var generation = 1L
    private var nextCommandId = 1L
    private val pending = linkedMapOf<Long, (String) -> Unit>()

    val pendingCount: Int
        get() = pending.size

    fun begin(onCancel: (String) -> Unit): AndroidContentPreparationToken {
        val commandId = nextCommandId
        nextCommandId = if (nextCommandId == Long.MAX_VALUE) 1L else nextCommandId + 1L
        pending[commandId] = onCancel
        return AndroidContentPreparationToken(generation, commandId)
    }

    fun finish(token: AndroidContentPreparationToken): Boolean {
        val existed = pending.remove(token.commandId) != null
        return existed && token.generation == generation
    }

    fun invalidate(reason: String): Int {
        generation = if (generation == Long.MAX_VALUE) 1L else generation + 1L
        val callbacks = pending.values.toList()
        pending.clear()
        callbacks.forEach { callback -> callback(reason) }
        return callbacks.size
    }
}

internal enum class AndroidContentTransport {
    OWNED_DESCRIPTOR,
    CACHE_SPOOL,
}

internal enum class AndroidContentDescriptorKind {
    REGULAR_FILE,
    FIFO,
    SOCKET,
    CHARACTER_DEVICE,
    BLOCK_DEVICE,
    OTHER,
    UNKNOWN,
}

internal fun androidContentTransport(
    kind: AndroidContentDescriptorKind,
    statSize: Long?,
): AndroidContentTransport =
    if (kind == AndroidContentDescriptorKind.REGULAR_FILE && statSize != null && statSize >= 0L) {
        AndroidContentTransport.OWNED_DESCRIPTOR
    } else {
        AndroidContentTransport.CACHE_SPOOL
    }

internal fun androidContentFallbackReason(kind: AndroidContentDescriptorKind): String = when (kind) {
    AndroidContentDescriptorKind.FIFO -> "fifo_descriptor"
    AndroidContentDescriptorKind.SOCKET -> "socket_descriptor"
    AndroidContentDescriptorKind.CHARACTER_DEVICE -> "character_device_descriptor"
    AndroidContentDescriptorKind.BLOCK_DEVICE -> "block_device_descriptor"
    AndroidContentDescriptorKind.OTHER -> "non_regular_descriptor"
    AndroidContentDescriptorKind.UNKNOWN -> "descriptor_stat_unavailable"
    AndroidContentDescriptorKind.REGULAR_FILE -> "regular_descriptor_size_unavailable"
}

/** Streaming copy used for non-seekable Android content-provider descriptors. */
internal object AndroidContentSpooler {
    private const val BUFFER_SIZE = 256 * 1024

    /**
     * Copies without buffering the complete source in memory and returns the exact byte count.
     * Empty and truncated provider streams are errors instead of becoming zero-length fd sources.
     */
    fun copy(
        input: InputStream,
        output: OutputStream,
        expectedLength: Long?,
        policy: AndroidContentSpoolPolicy = AndroidContentSpoolPolicy(),
        availableBytes: () -> Long = { Long.MAX_VALUE },
        cancelled: () -> Boolean = { false },
        onProgress: (Long) -> Unit = {},
    ): Long {
        require(expectedLength == null || expectedLength >= 0L) {
            "expectedLength must be null or non-negative"
        }
        if (expectedLength != null && expectedLength > policy.maxBytes) {
            throw AndroidContentSpoolException(
                "max_bytes_exceeded",
                "Android content provider declared $expectedLength bytes, exceeding the " +
                    "${policy.maxBytes}-byte spool limit",
            )
        }
        ensureDiskBudget(
            bytesRequired = expectedLength ?: 1L,
            policy = policy,
            availableBytes = availableBytes,
        )
        val buffer = ByteArray(BUFFER_SIZE)
        var total = 0L
        while (true) {
            throwIfCancelled(cancelled)
            val read = input.read(buffer)
            if (read < 0) {
                break
            }
            if (read == 0) {
                // InputStream permits a zero-byte read. Reading one byte prevents a faulty
                // provider implementation from causing a tight, non-progressing loop.
                val singleByte = input.read()
                if (singleByte < 0) {
                    break
                }
                val nextTotal = checkedByteCount(total, 1)
                validateNextWrite(
                    nextTotal = nextTotal,
                    writeBytes = 1,
                    expectedLength = expectedLength,
                    policy = policy,
                    availableBytes = availableBytes,
                )
                output.write(singleByte)
                total = nextTotal
                onProgress(total)
            } else {
                val nextTotal = checkedByteCount(total, read)
                validateNextWrite(
                    nextTotal = nextTotal,
                    writeBytes = read,
                    expectedLength = expectedLength,
                    policy = policy,
                    availableBytes = availableBytes,
                )
                output.write(buffer, 0, read)
                total = nextTotal
                onProgress(total)
            }
        }
        throwIfCancelled(cancelled)
        if (total == 0L) {
            throw EOFException("Android content provider returned an empty stream")
        }
        if (expectedLength != null && total != expectedLength) {
            throw EOFException(
                "Android content provider stream was truncated: " +
                    "expected $expectedLength bytes, received $total",
            )
        }
        return total
    }

    private fun validateNextWrite(
        nextTotal: Long,
        writeBytes: Int,
        expectedLength: Long?,
        policy: AndroidContentSpoolPolicy,
        availableBytes: () -> Long,
    ) {
        if (expectedLength != null && nextTotal > expectedLength) {
            throw AndroidContentSpoolException(
                "declared_length_exceeded",
                "Android content provider returned more than its declared $expectedLength bytes",
            )
        }
        if (nextTotal > policy.maxBytes) {
            throw AndroidContentSpoolException(
                "max_bytes_exceeded",
                "Android content provider exceeded the ${policy.maxBytes}-byte spool limit",
            )
        }
        ensureDiskBudget(writeBytes.toLong(), policy, availableBytes)
    }

    private fun ensureDiskBudget(
        bytesRequired: Long,
        policy: AndroidContentSpoolPolicy,
        availableBytes: () -> Long,
    ) {
        val available = availableBytes().coerceAtLeast(0L)
        if (available == Long.MAX_VALUE) {
            return
        }
        val required = try {
            Math.addExact(policy.minFreeBytes, bytesRequired)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
        if (available < required) {
            throw AndroidContentSpoolException(
                "insufficient_disk_budget",
                "Android content spool needs $bytesRequired bytes while preserving " +
                    "${policy.minFreeBytes} free bytes, but only $available bytes are available",
            )
        }
    }

    private fun throwIfCancelled(cancelled: () -> Boolean) {
        if (cancelled() || Thread.currentThread().isInterrupted) {
            throw AndroidContentPreparationCancelledException(
                "Android content preparation was cancelled while spooling",
            )
        }
    }

    private fun checkedByteCount(total: Long, read: Int): Long = try {
        Math.addExact(total, read.toLong())
    } catch (error: ArithmeticException) {
        throw IOException("Android content provider stream exceeded Long.MAX_VALUE bytes", error)
    }
}

internal fun deleteContentSpoolFile(file: File): Boolean {
    if (!file.exists()) {
        return true
    }
    repeat(3) {
        if (!file.exists() || file.delete()) {
            return true
        }
        Thread.yield()
    }
    return !file.exists()
}

internal fun androidContentSourceEvent(
    stage: String,
    authority: String?,
    fields: Map<String, Any?> = emptyMap(),
): String = buildString {
    append('{')
    appendJsonField("event", "android_content_source")
    append(',')
    appendJsonField("stage", stage)
    append(',')
    appendJsonField("authority", authority)
    fields.forEach { (name, value) ->
        append(',')
        appendJsonField(name, value)
    }
    append('}')
}

private fun StringBuilder.appendJsonField(name: String, value: Any?) {
    appendJsonString(name)
    append(':')
    when (value) {
        null -> append("null")
        is Boolean,
        is Byte,
        is Short,
        is Int,
        is Long,
        is Float,
        is Double -> append(value)
        else -> appendJsonString(value.toString())
    }
}

private fun StringBuilder.appendJsonString(value: String) {
    append('"')
    value.forEach { character ->
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> {
                if (character.code < 0x20) {
                    append("\\u")
                    append(character.code.toString(16).padStart(4, '0'))
                } else {
                    append(character)
                }
            }
        }
    }
    append('"')
}
