package app.slip.core.util

/**
 * Turns a peer-supplied `fileName` (which may contain `/` for folder sends) into a safe relative path.
 *
 * - `\` is treated as a separator, leading `/` stripped, `.` and `..` segments dropped
 * - characters illegal on common filesystems (`<>:"|?*` and control chars) become `_`
 * - trailing dots/spaces trimmed per segment (Windows/Android FAT), each segment capped at 255 bytes-ish
 * - an empty result becomes `"file"`
 */
object PathSanitizer {
    private val illegal = Regex("[<>:\"|?*\\x00-\\x1F\\x7F]")

    fun segments(fileName: String): List<String> {
        val parts = fileName.replace('\\', '/').split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "." && it != ".." }
            .map { seg ->
                var s = illegal.replace(seg, "_").trimEnd('.', ' ')
                if (s.isEmpty() || s == "." || s == "..") s = "_"
                if (s.length > 200) {
                    val dot = s.lastIndexOf('.')
                    s = if (dot > 0 && s.length - dot <= 16) s.take(200 - (s.length - dot)) + s.substring(dot) else s.take(200)
                }
                s
            }
        return parts.ifEmpty { listOf("file") }
    }

    fun sanitize(fileName: String): String = segments(fileName).joinToString("/")

    /** `name (n).ext` — inserts the counter before the extension. */
    fun withCounter(name: String, n: Int): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)"
    }
}
