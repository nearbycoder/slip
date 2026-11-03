package app.slip.android.data

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import app.slip.core.server.DirectoryStorage
import app.slip.core.server.IncomingFile
import app.slip.core.server.ReceiveStorage
import app.slip.core.server.SavedFile
import app.slip.core.util.PathSanitizer
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.time.Instant

/**
 * Saves into the public `Download/Slip` folder: through MediaStore (pending until committed) on Android 10+, or as a
 * plain file on 8–9 (falling back to the app's own Downloads dir without storage permission).
 */
class AndroidReceiveStorage(private val context: Context) : ReceiveStorage {
    override fun create(relativePath: String, size: Long, mimeType: String): IncomingFile {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) mediaStore(relativePath, mimeType) else legacy(relativePath, size, mimeType)
    }

    private fun resolveMime(name: String, given: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        val byExt = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        return when {
            byExt != null -> byExt
            given.isNotBlank() && given != "application/octet-stream" -> given
            else -> "application/octet-stream"
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.Q)
    private fun mediaStore(relativePath: String, mimeType: String): IncomingFile {
        val segments = PathSanitizer.segments(relativePath)
        val name = segments.last()
        val dirs = segments.dropLast(1)
        val relDir = (listOf(Environment.DIRECTORY_DOWNLOADS, "Slip") + dirs).joinToString("/") + "/"
        val mime = resolveMime(name, mimeType)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("MediaStore refused $relDir$name")
        val out: OutputStream = try {
            resolver.openOutputStream(uri, "w") ?: throw IOException("Cannot open $uri")
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return object : IncomingFile {
            override val output: OutputStream = out

            override fun commit(modified: Instant?): SavedFile {
                out.close()
                val done = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    if (modified != null) put(MediaStore.MediaColumns.DATE_MODIFIED, modified.epochSecond)
                }
                resolver.update(uri, done, null, null)
                var finalName = name
                var finalSize = 0L
                resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        finalName = c.getString(0) ?: name
                        finalSize = c.getLong(1)
                    }
                }
                val rel = (dirs + finalName).joinToString("/")
                return SavedFile(finalName, rel, uri.toString(), mime, finalSize)
            }

            override fun abort() {
                runCatching { out.close() }
                runCatching { resolver.delete(uri, null, null) }
            }
        }
    }

    private fun legacyRoot(): File {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        @Suppress("DEPRECATION")
        val public = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Slip")
        if (granted && (public.isDirectory || public.mkdirs())) return public
        return File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir, "Slip").apply { mkdirs() }
    }

    private fun legacy(relativePath: String, size: Long, mimeType: String): IncomingFile {
        val inner = DirectoryStorage(legacyRoot()).create(relativePath, size, mimeType)
        return object : IncomingFile by inner {
            override fun commit(modified: Instant?): SavedFile {
                val saved = inner.commit(modified)
                MediaScannerConnection.scanFile(context, arrayOf(saved.location), arrayOf(saved.mimeType), null)
                return saved.copy(mimeType = resolveMime(saved.displayName, mimeType))
            }
        }
    }

    companion object {
        /** A content URI another app can open for a saved file. */
        fun viewUri(context: Context, saved: SavedFile): Uri =
            if (saved.location.startsWith("content://")) Uri.parse(saved.location)
            else FileProvider.getUriForFile(context, context.packageName + ".files", File(saved.location))

        const val LOCATION_LABEL = "Download/Slip"
    }
}
