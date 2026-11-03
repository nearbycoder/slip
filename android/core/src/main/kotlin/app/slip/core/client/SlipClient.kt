package app.slip.core.client

import app.slip.core.SlipConstants
import app.slip.core.model.DeviceInfo
import app.slip.core.model.PrepareUploadRequest
import app.slip.core.model.PrepareUploadResponse
import app.slip.core.model.Protocol
import app.slip.core.model.SlipJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import java.io.IOException
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Where to reach a peer's HTTP(S) server. */
data class PeerAddress(val host: String, val port: Int = SlipConstants.DEFAULT_PORT, val protocol: Protocol = Protocol.HTTPS) {
    fun url(endpoint: String, query: Map<String, String> = emptyMap()): HttpUrl {
        val b = HttpUrl.Builder().scheme(protocol.wire).host(host).port(port)
            .encodedPath(SlipConstants.API_PREFIX + "/" + endpoint)
        query.forEach { (k, v) -> b.addQueryParameter(k, v) }
        return b.build()
    }

    override fun toString() = "${protocol.wire}://$host:$port"

    companion object {
        /** Parses `host`, `host:port`, or `http(s)://host:port`. */
        fun parse(value: String, defaultProtocol: Protocol = Protocol.HTTPS): PeerAddress {
            var v = value.trim()
            var proto = defaultProtocol
            if (v.startsWith("http://", true)) { proto = Protocol.HTTP; v = v.substring(7) }
            else if (v.startsWith("https://", true)) { proto = Protocol.HTTPS; v = v.substring(8) }
            v = v.substringBefore('/')
            val colon = v.lastIndexOf(':')
            return if (colon > 0 && !v.startsWith("[")) {
                PeerAddress(v.substring(0, colon), v.substring(colon + 1).toIntOrNull() ?: SlipConstants.DEFAULT_PORT, proto)
            } else {
                PeerAddress(v, SlipConstants.DEFAULT_PORT, proto)
            }
        }

        fun of(info: DeviceInfo, ip: String) = PeerAddress(ip, info.port, info.proto)
    }
}

sealed interface PrepareResult {
    data class Accepted(val response: PrepareUploadResponse) : PrepareResult
    /** 204: nothing to upload (text message delivered). */
    data object Finished : PrepareResult
    data object PinRequired : PrepareResult
    data object Declined : PrepareResult
    data object Busy : PrepareResult
    data object TooManyRequests : PrepareResult
    data class Error(val code: Int, val message: String) : PrepareResult
}

class HttpStatusException(val code: Int, message: String = "HTTP $code") : IOException(message)

/** Something to send: opened lazily and streamed, never loaded whole into memory. */
interface SendSource {
    val fileName: String
    /** Size in bytes, or -1 if unknown (then the upload is chunked). */
    val size: Long
    val mimeType: String
    val modified: java.time.Instant? get() = null
    val sha256: String? get() = null
    val preview: String? get() = null
    fun open(): java.io.InputStream
}

/**
 * HTTP client for talking to LocalSend-compatible peers. Accepts self-signed certificates (LocalSend endpoints never
 * have CA-issued ones); trust is by fingerprint at the application level.
 */
class SlipClient(base: OkHttpClient = defaultOkHttp()) {
    private val http = base
    private val prepareHttp = base.newBuilder()
        .readTimeout(SlipConstants.DECISION_TIMEOUT_MS + 30_000, TimeUnit.MILLISECONDS)
        .build()
    private val uploadHttp = base.newBuilder()
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    // Every call hops to IO: response bodies are read after await() resumes, which must never be the main thread.
    suspend fun info(target: PeerAddress): DeviceInfo = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(target.url("info")).get().build()
        http.newCall(req).await().use { resp ->
            if (!resp.isSuccessful) throw HttpStatusException(resp.code)
            SlipJson.decodeFromString(DeviceInfo.serializer(), resp.body.string())
        }
    }

    suspend fun register(target: PeerAddress, ours: DeviceInfo, timeoutMs: Long? = null): DeviceInfo = withContext(Dispatchers.IO) {
        val client = if (timeoutMs == null) http else http.newBuilder()
            .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .callTimeout(timeoutMs * 2, TimeUnit.MILLISECONDS)
            .build()
        val body = SlipJson.encodeToString(DeviceInfo.serializer(), ours).toRequestBody(jsonType)
        val req = Request.Builder().url(target.url("register")).post(body).build()
        client.newCall(req).await().use { resp ->
            if (!resp.isSuccessful) throw HttpStatusException(resp.code)
            SlipJson.decodeFromString(DeviceInfo.serializer(), resp.body.string())
        }
    }

    suspend fun prepareUpload(target: PeerAddress, request: PrepareUploadRequest, pin: String? = null): PrepareResult = withContext(Dispatchers.IO) {
        val query = if (pin.isNullOrEmpty()) emptyMap() else mapOf("pin" to pin)
        val body = SlipJson.encodeToString(PrepareUploadRequest.serializer(), request).toRequestBody(jsonType)
        val req = Request.Builder().url(target.url("prepare-upload", query)).post(body).build()
        prepareHttp.newCall(req).await().use { resp ->
            when (resp.code) {
                200 -> runCatching {
                    PrepareResult.Accepted(SlipJson.decodeFromString(PrepareUploadResponse.serializer(), resp.body.string()))
                }.getOrElse { PrepareResult.Error(200, "Invalid response: ${it.message}") }
                204 -> PrepareResult.Finished
                401 -> PrepareResult.PinRequired
                403 -> PrepareResult.Declined
                409 -> PrepareResult.Busy
                429 -> PrepareResult.TooManyRequests
                else -> PrepareResult.Error(resp.code, resp.body.string().take(200).ifBlank { "HTTP ${resp.code}" })
            }
        }
    }

    /** Streams [source] to the peer, reporting cumulative bytes to [onProgress]. Throws on non-2xx. */
    suspend fun upload(
        target: PeerAddress,
        sessionId: String,
        fileId: String,
        token: String,
        source: SendSource,
        onProgress: (Long) -> Unit = {},
    ): Unit = withContext(Dispatchers.IO) {
        val body = object : RequestBody() {
            override fun contentType() = "application/octet-stream".toMediaType()
            override fun contentLength() = source.size
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) {
                source.open().use { input ->
                    val buf = ByteArray(128 * 1024)
                    var total = 0L
                    var last = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        sink.write(buf, 0, n)
                        total += n
                        val now = System.nanoTime()
                        if (now - last > 50_000_000L) { last = now; onProgress(total) }
                    }
                    sink.flush()
                    onProgress(total)
                }
            }
        }
        val url = target.url("upload", mapOf("sessionId" to sessionId, "fileId" to fileId, "token" to token))
        val req = Request.Builder().url(url).post(body).build()
        uploadHttp.newCall(req).await().use { resp ->
            if (!resp.isSuccessful) throw HttpStatusException(resp.code)
        }
    }

    suspend fun cancel(target: PeerAddress, sessionId: String): Unit = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(target.url("cancel", mapOf("sessionId" to sessionId)))
            .post(ByteArray(0).toRequestBody(null)).build()
        runCatching { http.newCall(req).await().close() }
    }

    companion object {
        private val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }

        fun defaultOkHttp(): OkHttpClient {
            val ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf<TrustManager>(trustAll), SecureRandom()) }
            return OkHttpClient.Builder()
                .sslSocketFactory(ssl.socketFactory, trustAll)
                .hostnameVerifier { _, _ -> true }
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()
        }
    }
}

internal suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
}
