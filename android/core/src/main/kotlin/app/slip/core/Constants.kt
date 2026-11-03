package app.slip.core

/** Protocol constants shared by every Slip client (see protocol/IMPLEMENTATION.md). */
object SlipConstants {
    const val PROTOCOL_VERSION = "2.1"
    const val DEFAULT_PORT = 53317
    const val MULTICAST_GROUP = "224.0.0.167"
    const val MULTICAST_PORT = 53317
    const val API_PREFIX = "/api/localsend/v2"
    const val MULTICAST_TTL = 32

    /** How long prepare-upload is held open waiting for the user before answering 403. */
    const val DECISION_TIMEOUT_MS = 60_000L

    /** Peers not seen for this long drop off the list (unless a transfer with them is active). */
    const val PEER_EXPIRY_MS = 60_000L

    const val MAX_PARALLEL_UPLOADS = 3
}
