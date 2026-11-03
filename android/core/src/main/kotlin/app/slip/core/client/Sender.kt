package app.slip.core.client

import app.slip.core.SlipConstants
import app.slip.core.model.DeviceInfo
import app.slip.core.model.FileDto
import app.slip.core.model.FileMetadata
import app.slip.core.model.PrepareUploadRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.util.UUID

enum class SendStatus {
    PREPARING, WAITING, AWAITING_PIN, SENDING, DONE, DECLINED, BUSY, PIN_REQUIRED, TOO_MANY_REQUESTS, CANCELLED, FAILED;

    val isTerminal: Boolean get() = ordinal >= DONE.ordinal
}

enum class SendFileStatus { QUEUED, SENDING, DONE, SKIPPED, FAILED, CANCELLED }

data class SendFileState(
    val id: String,
    val fileName: String,
    val size: Long,
    val mimeType: String,
    val sent: Long = 0,
    val status: SendFileStatus = SendFileStatus.QUEUED,
    val error: String? = null,
)

data class SendState(
    val id: String,
    val target: PeerAddress,
    val targetAlias: String?,
    val status: SendStatus,
    val files: List<SendFileState>,
    val isText: Boolean = false,
    val error: String? = null,
    val startedAt: Long = System.currentTimeMillis(),
    val transferStartedAt: Long? = null,
    val endedAt: Long? = null,
) {
    val totalBytes: Long get() = files.filter { it.status != SendFileStatus.SKIPPED }.sumOf { it.size.coerceAtLeast(0) }
    val sentBytes: Long get() = files.sumOf { it.sent }

    /** Bytes/second since the upload phase began. */
    fun speed(now: Long = System.currentTimeMillis()): Long {
        val start = transferStartedAt ?: return 0
        val end = endedAt ?: now
        val ms = (end - start).coerceAtLeast(1)
        return sentBytes * 1000 / ms
    }
}

/** A running (or finished) outgoing transfer. */
class SendJob internal constructor(initial: SendState) {
    internal val mutable = MutableStateFlow(initial)
    val state: StateFlow<SendState> = mutable.asStateFlow()
    internal var job: Job? = null
    @Volatile internal var cancelRequested = false
    val id: String get() = initial.id
    private val initial = initial

    fun cancel() {
        cancelRequested = true
        job?.cancel()
    }

    suspend fun await(): SendState {
        job?.join()
        return state.value
    }
}

/**
 * Orchestrates outgoing transfers: prepare-upload (with PIN retry), then up to [SlipConstants.MAX_PARALLEL_UPLOADS]
 * concurrent streamed uploads with byte progress, and `/cancel` on user cancel.
 */
class Sender(
    private val client: SlipClient,
    private val ourInfo: () -> DeviceInfo,
    private val scope: CoroutineScope,
) {
    private val _jobs = MutableStateFlow<List<SendJob>>(emptyList())
    /** All jobs this session, newest first. */
    val jobs: StateFlow<List<SendJob>> = _jobs.asStateFlow()

    /**
     * Starts sending [sources] to [target]. [pinProvider] is asked for a PIN each time the receiver answers 401
     * (attempt counts from 1); returning null gives up.
     */
    fun send(
        target: PeerAddress,
        sources: List<SendSource>,
        targetAlias: String? = null,
        pinProvider: suspend (attempt: Int) -> String? = { null },
    ): SendJob {
        require(sources.isNotEmpty()) { "Nothing to send" }
        val ids = sources.map { UUID.randomUUID().toString() }
        val byId = ids.zip(sources).toMap()
        val isText = sources.size == 1 && sources[0] is TextSource
        val sendJob = SendJob(
            SendState(
                id = UUID.randomUUID().toString(),
                target = target,
                targetAlias = targetAlias,
                status = SendStatus.PREPARING,
                files = ids.zip(sources).map { (id, s) -> SendFileState(id, s.fileName, s.size, s.mimeType) },
                isText = isText,
            ),
        )
        _jobs.update { listOf(sendJob) + it }
        sendJob.job = scope.launch(Dispatchers.IO) {
            var sessionId: String? = null
            try {
                val dtos = byId.mapValues { (id, s) ->
                    FileDto(
                        id = id,
                        fileName = s.fileName,
                        size = s.size.coerceAtLeast(0),
                        fileType = s.mimeType,
                        sha256 = s.sha256,
                        preview = s.preview,
                        metadata = s.modified?.let { FileMetadata(modified = it.toString()) },
                    )
                }
                val request = PrepareUploadRequest(ourInfo(), dtos)
                var pin: String? = null
                var attempt = 0
                sendJob.mutable.update { it.copy(status = SendStatus.WAITING) }
                var accepted: app.slip.core.model.PrepareUploadResponse? = null
                while (accepted == null) {
                    run {
                        when (val r = client.prepareUpload(target, request, pin)) {
                            is PrepareResult.Accepted -> accepted = r.response
                            PrepareResult.Finished -> {
                                finish(sendJob, SendStatus.DONE) { f -> f.copy(status = SendFileStatus.DONE, sent = f.size.coerceAtLeast(0)) }
                                return@launch
                            }
                            PrepareResult.PinRequired -> {
                                attempt++
                                sendJob.mutable.update { it.copy(status = SendStatus.AWAITING_PIN) }
                                pin = if (attempt <= 5) pinProvider(attempt) else null
                                if (pin == null) {
                                    finish(sendJob, SendStatus.PIN_REQUIRED, "PIN required") { it }
                                    return@launch
                                }
                                sendJob.mutable.update { it.copy(status = SendStatus.WAITING) }
                            }
                            PrepareResult.Declined -> { finish(sendJob, SendStatus.DECLINED, "Declined") { it }; return@launch }
                            PrepareResult.Busy -> { finish(sendJob, SendStatus.BUSY, "Receiver is busy") { it }; return@launch }
                            PrepareResult.TooManyRequests -> { finish(sendJob, SendStatus.TOO_MANY_REQUESTS, "Too many requests") { it }; return@launch }
                            is PrepareResult.Error -> { finish(sendJob, SendStatus.FAILED, "Error ${r.code}: ${r.message}") { it }; return@launch }
                        }
                    }
                }
                val acceptedResponse = accepted!!
                sessionId = acceptedResponse.sessionId
                sendJob.mutable.update { s ->
                    s.copy(
                        status = SendStatus.SENDING,
                        transferStartedAt = System.currentTimeMillis(),
                        files = s.files.map { f -> if (f.id in acceptedResponse.files) f else f.copy(status = SendFileStatus.SKIPPED) },
                    )
                }
                val semaphore = Semaphore(SlipConstants.MAX_PARALLEL_UPLOADS)
                coroutineScope {
                    acceptedResponse.files.forEach { (fileId, token) ->
                        val source = byId[fileId] ?: return@forEach
                        launch {
                            semaphore.withPermit {
                                updateFile(sendJob, fileId) { it.copy(status = SendFileStatus.SENDING) }
                                try {
                                    client.upload(target, acceptedResponse.sessionId, fileId, token, source) { sent ->
                                        updateFile(sendJob, fileId) { it.copy(sent = sent) }
                                    }
                                    updateFile(sendJob, fileId) { it.copy(status = SendFileStatus.DONE, sent = maxOf(it.sent, it.size)) }
                                } catch (e: CancellationException) {
                                    throw e
                                } catch (e: Exception) {
                                    updateFile(sendJob, fileId) { it.copy(status = SendFileStatus.FAILED, error = e.message ?: e.javaClass.simpleName) }
                                }
                            }
                        }
                    }
                }
                val failed = sendJob.state.value.files.count { it.status == SendFileStatus.FAILED }
                if (failed == 0) finish(sendJob, SendStatus.DONE) { it }
                else finish(sendJob, SendStatus.FAILED, "$failed file(s) failed") { it }
            } catch (e: CancellationException) {
                withContext(NonCancellable) {
                    sessionId?.let { client.cancel(target, it) }
                    finish(sendJob, SendStatus.CANCELLED, "Cancelled") { f ->
                        if (f.status == SendFileStatus.DONE || f.status == SendFileStatus.SKIPPED) f else f.copy(status = SendFileStatus.CANCELLED)
                    }
                }
                throw e
            } catch (e: Exception) {
                finish(sendJob, SendStatus.FAILED, e.message ?: e.javaClass.simpleName) { it }
            }
        }
        return sendJob
    }

    fun sendText(target: PeerAddress, text: String, targetAlias: String? = null, pinProvider: suspend (Int) -> String? = { null }) =
        send(target, listOf(TextSource(text)), targetAlias, pinProvider)

    fun clearFinished() = _jobs.update { list -> list.filter { !it.state.value.status.isTerminal } }

    private fun updateFile(job: SendJob, fileId: String, change: (SendFileState) -> SendFileState) {
        job.mutable.update { s -> s.copy(files = s.files.map { if (it.id == fileId) change(it) else it }) }
    }

    private fun finish(job: SendJob, status: SendStatus, error: String? = null, fileChange: (SendFileState) -> SendFileState) {
        job.mutable.update { s ->
            s.copy(status = status, error = error, endedAt = System.currentTimeMillis(), files = s.files.map(fileChange))
        }
    }
}
