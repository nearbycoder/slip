package app.slip.core.util

import java.security.MessageDigest
import java.security.SecureRandom

private val HEX = "0123456789abcdef".toCharArray()

fun ByteArray.toHex(): String {
    val out = CharArray(size * 2)
    forEachIndexed { i, b ->
        val v = b.toInt() and 0xff
        out[i * 2] = HEX[v ushr 4]
        out[i * 2 + 1] = HEX[v and 0x0f]
    }
    return String(out)
}

fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

internal val secureRandom = SecureRandom()

/** Random lowercase hex string of [chars] characters. */
fun randomHex(chars: Int): String {
    val bytes = ByteArray((chars + 1) / 2)
    secureRandom.nextBytes(bytes)
    return bytes.toHex().take(chars)
}

/** URL-safe random token, used for per-file upload tokens. */
fun randomToken(): String = randomHex(32)
