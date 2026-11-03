package app.slip.core.server

import app.slip.core.util.PathSanitizer
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.UUID

/** Where a received file ended up. [location] is a filesystem path or a content:// URI string. */
data class SavedFile(
    val displayName: String,
    val relativePath: String,
    val location: String,
    val mimeType: String,
    val size: Long,
)

/** A file being received. Write to [output], then [commit] it (or [abort] to delete the partial data). */
interface IncomingFile {
    val output: OutputStream
    fun commit(modified: Instant?): SavedFile
    fun abort()
}

/**
 * Pluggable destination for received files, so the Android app can write through MediaStore while the CLI and tests
 * write to a directory. [relativePath] is already sanitised (see [PathSanitizer]) and may contain `/`.
 */
interface ReceiveStorage {
    fun create(relativePath: String, size: Long, mimeType: String): IncomingFile
}

/**
 * Writes to `<root>/<relativePath>`, streaming to a hidden `.slip-partial-*` file next to the target and renaming it
 * into place on commit, picking `name (1).ext`, `name (2).ext`, … if the name is taken.
 */
class DirectoryStorage(val root: File) : ReceiveStorage {
    private val lock = Any()

    override fun create(relativePath: String, size: Long, mimeType: String): IncomingFile {
        val segments = PathSanitizer.segments(relativePath)
        val rootCanonical = root.canonicalFile
        val parent = segments.dropLast(1).fold(rootCanonical) { dir, seg -> File(dir, seg) }
        if (!parent.canonicalPath.startsWith(rootCanonical.path)) throw IOException("Path escapes save directory")
        if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) throw IOException("Cannot create $parent")
        val partial = File(parent, ".slip-partial-${UUID.randomUUID()}")
        val out = FileOutputStream(partial)
        val name = segments.last()
        return object : IncomingFile {
            override val output: OutputStream = out

            override fun commit(modified: Instant?): SavedFile {
                runCatching { out.close() }
                val target = synchronized(lock) {
                    var candidate = File(parent, name)
                    var n = 1
                    while (candidate.exists()) candidate = File(parent, PathSanitizer.withCounter(name, n++))
                    try {
                        Files.move(partial.toPath(), candidate.toPath(), StandardCopyOption.ATOMIC_MOVE)
                    } catch (e: Exception) {
                        if (!partial.renameTo(candidate)) throw IOException("Cannot rename to $candidate", e)
                    }
                    candidate
                }
                if (modified != null) runCatching { target.setLastModified(modified.toEpochMilli()) }
                val rel = target.relativeTo(rootCanonical).invariantSeparatorsPath
                return SavedFile(target.name, rel, target.absolutePath, mimeType, target.length())
            }

            override fun abort() {
                runCatching { out.close() }
                partial.delete()
            }
        }
    }
}
