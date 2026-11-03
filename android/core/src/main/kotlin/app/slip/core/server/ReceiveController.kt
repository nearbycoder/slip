package app.slip.core.server

import app.slip.core.SlipConstants
import app.slip.core.http.HttpHandler
import app.slip.core.http.HttpRequest
import app.slip.core.http.HttpResponse
import app.slip.core.model.DeviceInfo
import app.slip.core.model.PrepareUploadRequest
import app.slip.core.model.PrepareUploadResponse
import app.slip.core.model.SlipJson
import app.slip.core.util.PathSanitizer
import app.slip.core.util.randomToken
import app.slip.core.util.toHex
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The receiving half of the protocol: routes for info/register/prepare-upload/upload/cancel plus the session state
 * machine. Plug it into a [app.slip.core.http.MiniHttpServer] as its [HttpHandler].
 */
class ReceiveController(
    private val config: () -> ServerConfig,
    private val storage: () -> ReceiveStorage,
    /** Called for every `/register` (and prepare-upload) caller with its TCP source address. */
    private val onPeer: (DeviceInfo, String) -> Unit = { _, _ -> },
    private val decisionTimeoutMs: Long = SlipConstants.DECISION_TIMEOUT_MS,
    private val log: (String) -> Unit = {},
) : HttpHandler {
    private val prefix = SlipConstants.API_PREFIX
    private val lock = Any()

    private val _session = MutableStateFlow<ReceiveSession?>(null)
    /** The current (awaiting or transferring) session, or the last one that ended. */
    val session: StateFlow<ReceiveSession?> = _session.asStateFlow()

    private val _pending = MutableStateFlow<IncomingRequest?>(null)
    /** A transfer request waiting for [respond]. */
    val pending: StateFlow<IncomingRequest?> = _pending.asStateFlow()

    private val _history = MutableStateFlow<List<ReceiveSession>>(emptyList())
    /** Ended sessions, newest first. */
    val history: StateFlow<List<ReceiveSession>> = _history.asStateFlow()

    private val _messages = MutableSharedFlow<TextMessage>(replay = 0, extraBufferCapacity = 32)
    val messages: SharedFlow<TextMessage> = _messages.asSharedFlow()

    private val _textHistory = MutableStateFlow<List<TextMessage>>(emptyList())
    val textHistory: StateFlow<List<TextMessage>> = _textHistory.asStateFlow()

    private var decision: CompletableDeferred<Decision>? = null
    private var tokens: Map<String, String> = emptyMap()
    private val inFlight = ConcurrentHashMap<String, IncomingFile>()
    @Volatile private var cancelledSession: String? = null

    /** Answer the [pending] request. */
    fun respond(decision: Decision) {
        synchronized(lock) { this.decision }?.complete(decision)
    }

    /** User-side cancel of the current session (also used when the sender calls /cancel). */
    fun cancelCurrent() {
        val current = _session.value ?: return
        if (current.status == SessionStatus.AWAITING) {
            respond(Decision.Decline)
            return
        }
        if (current.status != SessionStatus.TRANSFERRING) return
        cancelledSession = current.id
        inFlight.values.forEach { runCatching { it.abort() } }
        endSession(SessionStatus.CANCELLED) { f -> if (f.status.isTerminal) f else f.copy(status = FileStatus.CANCELLED) }
    }

    override fun handle(request: HttpRequest): HttpResponse {
        val path = request.path.trimEnd('/')
        if (!path.startsWith(prefix)) return HttpResponse.status(404)
        return when (path.removePrefix(prefix)) {
            "/info" -> if (request.method == "GET" || request.method == "POST") info() else HttpResponse.status(405)
            "/register" -> if (request.method == "POST") register(request) else HttpResponse.status(405)
            "/prepare-upload" -> if (request.method == "POST") prepareUpload(request) else HttpResponse.status(405)
            "/upload" -> if (request.method == "POST") upload(request) else HttpResponse.status(405)
            "/cancel" -> if (request.method == "POST") cancel(request) else HttpResponse.status(405)
            else -> HttpResponse.status(404)
        }
    }

    private fun info() = HttpResponse.json(200, SlipJson.encodeToString(DeviceInfo.serializer(), config().info))

    private fun register(request: HttpRequest): HttpResponse {
        val peer = runCatching {
            SlipJson.decodeFromString(DeviceInfo.serializer(), request.readBodyBytes(64 * 1024).decodeToString())
        }.getOrElse { return HttpResponse.status(400) }
        val ours = config().info
        if (peer.fingerprint != ours.fingerprint) runCatching { onPeer(peer, request.remoteAddress) }
        return HttpResponse.json(200, SlipJson.encodeToString(DeviceInfo.serializer(), ours))
    }

    private fun prepareUpload(request: HttpRequest): HttpResponse {
        val cfg = config()
        val pin = cfg.pin
        if (!pin.isNullOrEmpty() && request.query["pin"] != pin) return HttpResponse.status(401)

        val body = runCatching {
            SlipJson.decodeFromString(PrepareUploadRequest.serializer(), request.readBodyBytes(16 * 1024 * 1024).decodeToString())
        }.getOrElse {
            log("prepare-upload from ${request.remoteAddress}: invalid body (${it.message})")
            return HttpResponse.status(400)
        }
        if (body.files.isEmpty()) return HttpResponse.status(400)
        // Normalise: the map key is authoritative for the id.
        val files = body.files.mapValues { (k, v) -> v.copy(id = k) }
        val ip = request.remoteAddress
        if (body.info.fingerprint != cfg.info.fingerprint) runCatching { onPeer(body.info, ip) }

        val deferred: CompletableDeferred<Decision>
        val requestId = UUID.randomUUID().toString()
        synchronized(lock) {
            if (_session.value?.isActive == true) return HttpResponse.status(409)
            if (body.isTextMessage) {
                val text = files.values.joinToString("\n") { it.preview.orEmpty() }
                val msg = TextMessage(body.info, ip, text)
                _textHistory.update { (listOf(msg) + it).take(100) }
                _messages.tryEmit(msg)
                return HttpResponse.status(204)
            }
            deferred = CompletableDeferred()
            decision = deferred
            _session.value = ReceiveSession(requestId, body.info, ip, files.mapValues { ReceivingFile(it.value) }, SessionStatus.AWAITING)
            if (!cfg.autoAccept) _pending.value = IncomingRequest(requestId, body.info, ip, files.values.toList())
        }

        val result = if (cfg.autoAccept) Decision.Accept(null) else runBlocking {
            withTimeoutOrNull(decisionTimeoutMs) { deferred.await() }
        } ?: Decision.Decline

        synchronized(lock) {
            decision = null
            _pending.value = null
            val accepted = (result as? Decision.Accept)?.let { a -> a.fileIds?.intersect(files.keys) ?: files.keys }.orEmpty()
            if (result is Decision.Decline || accepted.isEmpty() || _session.value?.id != requestId) {
                if (_session.value?.id == requestId) endSession(SessionStatus.DECLINED) { it.copy(status = FileStatus.SKIPPED) }
                return HttpResponse.status(403)
            }
            tokens = accepted.associateWith { randomToken() }
            cancelledSession = null
            _session.value = _session.value?.copy(
                status = SessionStatus.TRANSFERRING,
                files = files.mapValues { (id, f) -> ReceivingFile(f, if (id in accepted) FileStatus.PENDING else FileStatus.SKIPPED) },
                startedAt = System.currentTimeMillis(),
            )
            return HttpResponse.json(200, SlipJson.encodeToString(PrepareUploadResponse.serializer(), PrepareUploadResponse(requestId, tokens)))
        }
    }

    private fun upload(request: HttpRequest): HttpResponse {
        val sessionId = request.query["sessionId"]
        val fileId = request.query["fileId"]
        val token = request.query["token"]
        if (sessionId.isNullOrEmpty() || fileId.isNullOrEmpty() || token.isNullOrEmpty()) return HttpResponse.status(400)

        val dto = synchronized(lock) {
            val s = _session.value
            if (s == null || s.id != sessionId || s.status != SessionStatus.TRANSFERRING) return HttpResponse.status(403)
            if (s.senderIp != request.remoteAddress) return HttpResponse.status(403)
            if (tokens[fileId] == null || tokens[fileId] != token) return HttpResponse.status(403)
            val f = s.files[fileId] ?: return HttpResponse.status(403)
            if (f.status != FileStatus.PENDING && f.status != FileStatus.FAILED) return HttpResponse.status(409)
            updateFile(fileId) { it.copy(status = FileStatus.RECEIVING, bytes = 0, error = null) }
            f.dto
        }

        val incoming = try {
            storage().create(PathSanitizer.sanitize(dto.fileName), dto.size, dto.fileType)
        } catch (e: Exception) {
            finishFile(fileId) { it.copy(status = FileStatus.FAILED, error = e.message ?: "Cannot create file") }
            return HttpResponse.status(500)
        }
        inFlight[fileId] = incoming

        val digest = dto.sha256?.takeIf { it.isNotBlank() }?.let { MessageDigest.getInstance("SHA-256") }
        var received = 0L
        try {
            val buf = ByteArray(128 * 1024)
            var lastEmit = 0L
            val out = incoming.output
            while (true) {
                if (cancelledSession == sessionId) throw CancelledException()
                val n = request.body.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
                digest?.update(buf, 0, n)
                received += n
                val now = System.nanoTime()
                if (now - lastEmit > 100_000_000L) {
                    lastEmit = now
                    val r = received
                    synchronized(lock) { if (_session.value?.id == sessionId) updateFile(fileId) { it.copy(bytes = r) } }
                }
            }
            out.flush()
            if (cancelledSession == sessionId) throw CancelledException()
            if (digest != null && !digest.digest().toHex().equals(dto.sha256!!.trim(), ignoreCase = true)) {
                incoming.abort()
                inFlight.remove(fileId)
                finishFile(fileId) { it.copy(status = FileStatus.FAILED, bytes = received, error = "Checksum mismatch") }
                return HttpResponse.status(422)
            }
            val saved = incoming.commit(parseInstant(dto.metadata?.modified))
            inFlight.remove(fileId)
            finishFile(fileId) { it.copy(status = FileStatus.DONE, bytes = received, saved = saved) }
            return HttpResponse.status(200)
        } catch (e: CancelledException) {
            incoming.abort()
            inFlight.remove(fileId)
            return HttpResponse.status(409)
        } catch (e: IOException) {
            incoming.abort()
            inFlight.remove(fileId)
            finishFile(fileId) { it.copy(status = FileStatus.FAILED, bytes = received, error = e.message ?: "I/O error") }
            return HttpResponse.status(500)
        }
    }

    private fun cancel(request: HttpRequest): HttpResponse {
        val sessionId = request.query["sessionId"]
        val s = _session.value
        // Match the session id; older senders cancel without one, so then accept the sender's own IP.
        val matches = if (sessionId.isNullOrEmpty()) s?.senderIp == request.remoteAddress else s?.id == sessionId
        if (s != null && s.isActive && matches) cancelCurrent()
        return HttpResponse.status(200)
    }

    private fun updateFile(fileId: String, change: (ReceivingFile) -> ReceivingFile) {
        val s = _session.value ?: return
        val f = s.files[fileId] ?: return
        _session.value = s.copy(files = s.files + (fileId to change(f)))
    }

    private fun finishFile(fileId: String, change: (ReceivingFile) -> ReceivingFile) = synchronized(lock) {
        val s = _session.value ?: return@synchronized
        if (s.status != SessionStatus.TRANSFERRING) return@synchronized
        updateFile(fileId, change)
        val now = _session.value ?: return@synchronized
        if (now.files.values.all { it.status.isTerminal }) {
            val anyDone = now.files.values.any { it.status == FileStatus.DONE }
            endSession(if (anyDone) SessionStatus.FINISHED else SessionStatus.FAILED) { it }
        }
    }

    private fun endSession(status: SessionStatus, fileChange: (ReceivingFile) -> ReceivingFile) = synchronized(lock) {
        val s = _session.value ?: return@synchronized
        val ended = s.copy(status = status, files = s.files.mapValues { fileChange(it.value) }, endedAt = System.currentTimeMillis())
        _session.value = ended
        tokens = emptyMap()
        _history.update { (listOf(ended) + it).take(100) }
    }

    private class CancelledException : Exception()

    companion object {
        fun parseInstant(value: String?): Instant? {
            if (value.isNullOrBlank()) return null
            return runCatching { Instant.parse(value) }.getOrNull()
                ?: runCatching { OffsetDateTime.parse(value).toInstant() }.getOrNull()
                ?: runCatching { java.time.LocalDateTime.parse(value).atZone(java.time.ZoneId.systemDefault()).toInstant() }.getOrNull()
        }
    }
}
