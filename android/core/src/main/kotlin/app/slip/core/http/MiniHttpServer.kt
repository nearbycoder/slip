package app.slip.core.http

import java.io.BufferedInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URLDecoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket

class HttpRequest(
    val method: String,
    val path: String,
    val query: Map<String, String>,
    /** Header names are lower-cased. */
    val headers: Map<String, String>,
    val remoteAddress: String,
    /** The request body, bounded to the declared length (or de-chunked). Read it at most once. */
    val body: InputStream,
    /** Declared Content-Length, or -1 when chunked/unknown. */
    val contentLength: Long,
) {
    fun readBodyBytes(limit: Int = 8 * 1024 * 1024): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (true) {
            val n = body.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            if (out.size() > limit) throw IOException("Body too large")
        }
        return out.toByteArray()
    }
}

class HttpResponse(
    val status: Int,
    val body: ByteArray = ByteArray(0),
    val contentType: String? = null,
) {
    companion object {
        fun json(status: Int, json: String) = HttpResponse(status, json.toByteArray(), "application/json; charset=utf-8")
        fun status(status: Int) = HttpResponse(status)
    }
}

fun interface HttpHandler {
    /** Called on a dedicated connection thread; blocking (e.g. awaiting a user decision) is fine. */
    fun handle(request: HttpRequest): HttpResponse
}

/**
 * A small, dependency-free HTTP/1.1 server (plain or TLS) built on blocking sockets with a thread per connection.
 * It streams request bodies (Content-Length or chunked), honours `Expect: 100-continue` and keep-alive, and works
 * identically on the JVM and on Android.
 */
class MiniHttpServer(
    private val port: Int,
    private val sslContext: SSLContext?,
    private val handler: HttpHandler,
    private val bindAddress: InetAddress? = null,
) {
    private var serverSocket: ServerSocket? = null
    private var executor: ExecutorService? = null
    private val connections = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<Socket, Boolean>())

    val localPort: Int get() = serverSocket?.localPort ?: -1

    @Synchronized
    fun start(): Int {
        check(serverSocket == null) { "already started" }
        val ss: ServerSocket = if (sslContext != null) {
            (sslContext.serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
                needClientAuth = false
                wantClientAuth = false
            }
        } else {
            ServerSocket()
        }
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(bindAddress, port), 128)
        serverSocket = ss
        val counter = AtomicInteger()
        val pool = Executors.newCachedThreadPool { r ->
            Thread(r, "slip-http-${counter.incrementAndGet()}").apply { isDaemon = true }
        }
        executor = pool
        Thread({ acceptLoop(ss, pool) }, "slip-http-accept").apply { isDaemon = true }.start()
        return ss.localPort
    }

    @Synchronized
    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        connections.forEach { runCatching { it.close() } }
        connections.clear()
        executor?.shutdownNow()
        executor = null
    }

    private fun acceptLoop(ss: ServerSocket, pool: ExecutorService) {
        while (!ss.isClosed) {
            val socket = try {
                ss.accept()
            } catch (e: IOException) {
                if (ss.isClosed) return else continue
            }
            try {
                pool.execute { serve(socket) }
            } catch (e: Exception) {
                runCatching { socket.close() }
            }
        }
    }

    private fun serve(socket: Socket) {
        connections += socket
        try {
            socket.soTimeout = 60_000
            socket.tcpNoDelay = true
            val input = BufferedInputStream(socket.getInputStream(), 64 * 1024)
            val output = socket.getOutputStream()
            val remote = (socket.remoteSocketAddress as? InetSocketAddress)?.address?.hostAddress?.removePrefix("::ffff:") ?: ""
            while (!socket.isClosed) {
                val keepAlive = handleOne(input, output, remote) ?: break
                if (!keepAlive) break
            }
        } catch (_: SocketException) {
        } catch (_: EOFException) {
        } catch (_: IOException) {
        } finally {
            connections -= socket
            runCatching { socket.close() }
        }
    }

    /** Returns whether to keep the connection open, or null when the peer closed it before sending a request. */
    private fun handleOne(input: BufferedInputStream, output: OutputStream, remote: String): Boolean? {
        val requestLine = readLine(input) ?: return null
        if (requestLine.isEmpty()) return true
        val parts = requestLine.split(' ')
        if (parts.size < 3) {
            writeResponse(output, HttpResponse.status(400), false)
            return false
        }
        val method = parts[0].uppercase()
        val target = parts[1]
        val httpVersion = parts[2]
        val headers = LinkedHashMap<String, String>()
        var headerBytes = 0
        while (true) {
            val line = readLine(input) ?: throw EOFException()
            if (line.isEmpty()) break
            headerBytes += line.length
            if (headerBytes > 64 * 1024) {
                writeResponse(output, HttpResponse.status(431), false)
                return false
            }
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
        }

        val qIndex = target.indexOf('?')
        val rawPath = if (qIndex >= 0) target.substring(0, qIndex) else target
        val query = if (qIndex >= 0) parseQuery(target.substring(qIndex + 1)) else emptyMap()
        val path = runCatching { URLDecoder.decode(rawPath.replace("+", "%2B"), "UTF-8") }.getOrDefault(rawPath)

        val chunked = headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true
        val contentLength = if (chunked) -1L else headers["content-length"]?.toLongOrNull() ?: 0L
        if (headers["expect"].equals("100-continue", ignoreCase = true)) {
            output.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
            output.flush()
        }
        val body: BodyStream = if (chunked) ChunkedBodyStream(input) else FixedBodyStream(input, contentLength)

        val connectionHeader = headers["connection"]?.lowercase()
        var keepAlive = when {
            connectionHeader?.contains("close") == true -> false
            httpVersion == "HTTP/1.0" -> connectionHeader?.contains("keep-alive") == true
            else -> true
        }

        val request = HttpRequest(method, path, query, headers, remote, body, contentLength)
        val response = try {
            handler.handle(request)
        } catch (e: Throwable) {
            if (e is InterruptedException) throw e
            HttpResponse.status(500)
        }
        // Leave the connection reusable only if the unread rest of the body is small enough to skip.
        if (keepAlive && !body.drain(1L shl 20)) keepAlive = false
        writeResponse(output, response, keepAlive)
        return keepAlive
    }

    private fun writeResponse(output: OutputStream, response: HttpResponse, keepAlive: Boolean) {
        val sb = StringBuilder()
        sb.append("HTTP/1.1 ").append(response.status).append(' ').append(reason(response.status)).append("\r\n")
        if (response.contentType != null) sb.append("Content-Type: ").append(response.contentType).append("\r\n")
        sb.append("Content-Length: ").append(response.body.size).append("\r\n")
        sb.append("Connection: ").append(if (keepAlive) "keep-alive" else "close").append("\r\n")
        sb.append("\r\n")
        output.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        if (response.body.isNotEmpty()) output.write(response.body)
        output.flush()
    }

    companion object {
        internal fun readLine(input: InputStream): String? {
            val sb = StringBuilder()
            while (true) {
                val c = input.read()
                if (c < 0) return if (sb.isEmpty()) null else sb.toString()
                if (c == '\n'.code) break
                if (c != '\r'.code) sb.append(c.toChar())
                if (sb.length > 16 * 1024) throw IOException("Line too long")
            }
            return sb.toString()
        }

        fun parseQuery(q: String): Map<String, String> = q.split('&').filter { it.isNotEmpty() }.associate { kv ->
            val eq = kv.indexOf('=')
            val k = if (eq >= 0) kv.substring(0, eq) else kv
            val v = if (eq >= 0) kv.substring(eq + 1) else ""
            decode(k) to decode(v)
        }

        private fun decode(s: String) = runCatching { URLDecoder.decode(s, "UTF-8") }.getOrDefault(s)

        fun reason(status: Int): String = when (status) {
            100 -> "Continue"
            200 -> "OK"
            204 -> "No Content"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            405 -> "Method Not Allowed"
            409 -> "Conflict"
            422 -> "Unprocessable Entity"
            429 -> "Too Many Requests"
            431 -> "Request Header Fields Too Large"
            500 -> "Internal Server Error"
            else -> "Status"
        }
    }
}

internal abstract class BodyStream : InputStream() {
    /** Reads and discards what is left, up to [max] bytes. Returns true if the body is now fully consumed. */
    fun drain(max: Long): Boolean = try {
        val buf = ByteArray(8192)
        var total = 0L
        while (true) {
            val n = read(buf)
            if (n < 0) break
            total += n
            if (total > max) return false
        }
        true
    } catch (e: IOException) {
        false
    }
}

internal class FixedBodyStream(private val input: InputStream, length: Long) : BodyStream() {
    private var remaining = length

    override fun read(): Int {
        if (remaining <= 0) return -1
        val c = input.read()
        if (c < 0) throw EOFException("Body truncated")
        remaining--
        return c
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (remaining <= 0) return -1
        val n = input.read(b, off, minOf(len.toLong(), remaining).toInt())
        if (n < 0) throw EOFException("Body truncated")
        remaining -= n
        return n
    }

    override fun available(): Int = minOf(input.available().toLong(), remaining).toInt()
}

internal class ChunkedBodyStream(private val input: InputStream) : BodyStream() {
    private var chunkRemaining = 0L
    private var done = false

    private fun nextChunk(): Boolean {
        if (done) return false
        if (chunkRemaining == 0L) {
            val line = MiniHttpServer.readLine(input) ?: throw EOFException()
            val sizeStr = line.substringBefore(';').trim()
            val size = sizeStr.toLongOrNull(16) ?: throw IOException("Bad chunk size: $line")
            if (size == 0L) {
                while (true) {
                    val trailer = MiniHttpServer.readLine(input) ?: break
                    if (trailer.isEmpty()) break
                }
                done = true
                return false
            }
            chunkRemaining = size
        }
        return true
    }

    override fun read(): Int {
        val b = ByteArray(1)
        val n = read(b, 0, 1)
        return if (n < 0) -1 else b[0].toInt() and 0xff
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (!nextChunk()) return -1
        val n = input.read(b, off, minOf(len.toLong(), chunkRemaining).toInt())
        if (n < 0) throw EOFException("Chunk truncated")
        chunkRemaining -= n
        if (chunkRemaining == 0L) {
            // CRLF after the chunk data
            MiniHttpServer.readLine(input)
        }
        return n
    }
}
