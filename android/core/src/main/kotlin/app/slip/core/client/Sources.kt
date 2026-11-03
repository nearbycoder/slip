package app.slip.core.client

import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.URLConnection
import java.time.Instant
import java.util.UUID

/** A file on disk, sent as [fileName] (which may be a relative path such as `Photos/a.jpg`). */
class FileSource(val file: File, override val fileName: String = file.name) : SendSource {
    override val size: Long get() = file.length()
    override val mimeType: String = guessMime(file.name)
    override val modified: Instant? get() = file.lastModified().takeIf { it > 0 }?.let(Instant::ofEpochMilli)
    override fun open(): InputStream = FileInputStream(file)

    companion object {
        /** A file, or every regular file under a directory with paths relative to its parent (folder name included). */
        fun expand(file: File): List<FileSource> {
            if (!file.isDirectory) return listOf(FileSource(file))
            val base = file.absoluteFile.parentFile
            return file.walkTopDown()
                .filter { it.isFile && !it.name.startsWith(".slip-partial-") }
                .map { FileSource(it, it.absoluteFile.relativeTo(base).invariantSeparatorsPath) }
                .toList()
        }
    }
}

/** A text message: one `text/plain` file whose content travels as `preview`. */
class TextSource(val text: String) : SendSource {
    private val bytes = text.toByteArray(Charsets.UTF_8)
    override val fileName: String = "${UUID.randomUUID()}.txt"
    override val size: Long = bytes.size.toLong()
    override val mimeType: String = "text/plain"
    override val preview: String = text
    override fun open(): InputStream = ByteArrayInputStream(bytes)
}

fun guessMime(name: String): String {
    val ext = name.substringAfterLast('.', "").lowercase()
    val known = when (ext) {
        "apk" -> "application/vnd.android.package-archive"
        "heic" -> "image/heic"
        "webp" -> "image/webp"
        "mkv" -> "video/x-matroska"
        "md" -> "text/markdown"
        "json" -> "application/json"
        "7z" -> "application/x-7z-compressed"
        else -> null
    }
    return known ?: runCatching { URLConnection.guessContentTypeFromName(name) }.getOrNull() ?: "application/octet-stream"
}
