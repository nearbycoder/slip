package app.slip.android.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import app.slip.core.client.SendSource
import app.slip.core.client.guessMime
import java.io.IOException
import java.io.InputStream
import java.time.Instant

/** A file behind a content:// URI (picker, share sheet or document tree), streamed through the ContentResolver. */
class UriSource(
    private val context: Context,
    val uri: Uri,
    override val fileName: String,
    override val size: Long,
    override val mimeType: String,
    override val modified: Instant? = null,
) : SendSource {
    override fun open(): InputStream = context.contentResolver.openInputStream(uri) ?: throw IOException("Cannot open $uri")

    companion object {
        fun from(context: Context, uri: Uri): UriSource {
            var name: String? = null
            var size = -1L
            runCatching {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                    }
                }
            }
            val fileName = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
            if (size < 0) {
                size = runCatching { context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1L
            }
            val mime = context.contentResolver.getType(uri) ?: guessMime(fileName)
            return UriSource(context, uri, fileName, size, mime)
        }

        /** Every file under a picked folder, named `Folder/sub/file.ext`. */
        fun fromTree(context: Context, treeUri: Uri): Pair<String, List<UriSource>> {
            val root = DocumentFile.fromTreeUri(context, treeUri) ?: return "Folder" to emptyList()
            val rootName = root.name ?: "Folder"
            val out = ArrayList<UriSource>()
            fun walk(dir: DocumentFile, prefix: String) {
                for (child in dir.listFiles()) {
                    val name = child.name ?: continue
                    if (child.isDirectory) walk(child, "$prefix$name/")
                    else if (child.isFile) out += UriSource(
                        context, child.uri, "$prefix$name", child.length(),
                        child.type ?: guessMime(name),
                        child.lastModified().takeIf { it > 0 }?.let(Instant::ofEpochMilli),
                    )
                }
            }
            walk(root, "$rootName/")
            return rootName to out
        }
    }
}
