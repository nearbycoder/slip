package app.slip.core.model

import app.slip.core.SlipConstants
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The one JSON configuration every Slip component uses: lenient, ignores unknown keys, fills defaults. */
val SlipJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    encodeDefaults = true
    explicitNulls = true
}

enum class Protocol(val wire: String) {
    HTTP("http"), HTTPS("https");

    companion object {
        fun parse(value: String?): Protocol = if (value.equals("http", ignoreCase = true)) HTTP else HTTPS
    }
}

enum class DeviceType(val wire: String) {
    MOBILE("mobile"), DESKTOP("desktop"), WEB("web"), HEADLESS("headless"), SERVER("server");

    companion object {
        /** Unknown or missing values fall back to desktop, as the official implementation does. */
        fun parse(value: String?): DeviceType = entries.firstOrNull { it.wire.equals(value, ignoreCase = true) } ?: DESKTOP
    }
}

@Serializable
data class DeviceInfo(
    val alias: String = "Unknown",
    val version: String = SlipConstants.PROTOCOL_VERSION,
    val deviceModel: String? = null,
    val deviceType: String? = null,
    val fingerprint: String = "",
    val port: Int = SlipConstants.DEFAULT_PORT,
    val protocol: String = "https",
    val download: Boolean = false,
) {
    val type: DeviceType get() = DeviceType.parse(deviceType)
    val proto: Protocol get() = Protocol.parse(protocol)
}

/** A multicast packet: DeviceInfo plus `announce` and its legacy v1 twin `announcement`. */
@Serializable
data class MulticastMessage(
    val alias: String = "Unknown",
    val version: String = SlipConstants.PROTOCOL_VERSION,
    val deviceModel: String? = null,
    val deviceType: String? = null,
    val fingerprint: String = "",
    val port: Int = SlipConstants.DEFAULT_PORT,
    val protocol: String = "https",
    val download: Boolean = false,
    val announce: Boolean? = null,
    val announcement: Boolean? = null,
) {
    val isAnnounce: Boolean get() = announce ?: announcement ?: false

    fun toDeviceInfo() = DeviceInfo(alias, version, deviceModel, deviceType, fingerprint, port, protocol, download)

    companion object {
        fun from(info: DeviceInfo, announce: Boolean) = MulticastMessage(
            info.alias, info.version, info.deviceModel, info.deviceType, info.fingerprint,
            info.port, info.protocol, info.download, announce = announce, announcement = announce,
        )
    }
}

@Serializable
data class FileMetadata(
    val modified: String? = null,
    val accessed: String? = null,
)

@Serializable
data class FileDto(
    val id: String,
    val fileName: String,
    val size: Long = 0,
    val fileType: String = "application/octet-stream",
    val sha256: String? = null,
    val preview: String? = null,
    val metadata: FileMetadata? = null,
)

@Serializable
data class PrepareUploadRequest(
    val info: DeviceInfo,
    val files: Map<String, FileDto>,
) {
    /** Every file is text/ with an inline preview: a message, answered 204 with no upload. */
    val isTextMessage: Boolean
        get() = files.isNotEmpty() && files.values.all { it.fileType.startsWith("text/") && it.preview != null }
}

@Serializable
data class PrepareUploadResponse(
    val sessionId: String,
    val files: Map<String, String>,
)
