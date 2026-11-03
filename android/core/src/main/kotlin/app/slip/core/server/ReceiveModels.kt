package app.slip.core.server

import app.slip.core.model.DeviceInfo
import app.slip.core.model.FileDto

enum class FileStatus { PENDING, RECEIVING, DONE, FAILED, SKIPPED, CANCELLED;

    val isTerminal: Boolean get() = this == DONE || this == FAILED || this == SKIPPED || this == CANCELLED
}

data class ReceivingFile(
    val dto: FileDto,
    val status: FileStatus = FileStatus.PENDING,
    val bytes: Long = 0,
    val saved: SavedFile? = null,
    val error: String? = null,
)

/** A prepare-upload waiting for the user's decision. */
data class IncomingRequest(
    val id: String,
    val sender: DeviceInfo,
    val senderIp: String,
    val files: List<FileDto>,
) {
    val totalSize: Long get() = files.sumOf { it.size }
}

sealed interface Decision {
    /** Accept [fileIds] (null = all). */
    data class Accept(val fileIds: Set<String>? = null) : Decision
    data object Decline : Decision
}

enum class SessionStatus { AWAITING, TRANSFERRING, FINISHED, FAILED, CANCELLED, DECLINED }

data class ReceiveSession(
    val id: String,
    val sender: DeviceInfo,
    val senderIp: String,
    val files: Map<String, ReceivingFile>,
    val status: SessionStatus,
    val startedAt: Long = System.currentTimeMillis(),
    val endedAt: Long? = null,
) {
    val accepted: List<ReceivingFile> get() = files.values.filter { it.status != FileStatus.SKIPPED }
    val totalBytes: Long get() = accepted.sumOf { it.dto.size }
    val receivedBytes: Long get() = accepted.sumOf { it.bytes }
    val isActive: Boolean get() = status == SessionStatus.AWAITING || status == SessionStatus.TRANSFERRING
}

data class TextMessage(
    val sender: DeviceInfo,
    val senderIp: String,
    val text: String,
    val receivedAt: Long = System.currentTimeMillis(),
)

/** What the server needs to know about us, read fresh on every request. */
data class ServerConfig(
    val info: DeviceInfo,
    val pin: String? = null,
    val autoAccept: Boolean = false,
)
