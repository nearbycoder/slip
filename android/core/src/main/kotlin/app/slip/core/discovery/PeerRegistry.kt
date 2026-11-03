package app.slip.core.discovery

import app.slip.core.client.PeerAddress
import app.slip.core.model.DeviceInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

enum class DiscoveredVia { MULTICAST, REGISTER, SCAN, MANUAL }

data class Peer(
    val info: DeviceInfo,
    val ip: String,
    val lastSeen: Long,
    val via: DiscoveredVia,
) {
    val fingerprint: String get() = info.fingerprint
    val address: PeerAddress get() = PeerAddress.of(info, ip)
}

/** Nearby peers keyed by fingerprint, expiring after a period of silence. */
class PeerRegistry(private val clock: () -> Long = System::currentTimeMillis) {
    private val _peers = MutableStateFlow<List<Peer>>(emptyList())
    val peers: StateFlow<List<Peer>> = _peers.asStateFlow()

    fun upsert(info: DeviceInfo, ip: String, via: DiscoveredVia) {
        val key = info.fingerprint.ifEmpty { "$ip:${info.port}" }
        _peers.update { list ->
            val peer = Peer(info.copy(fingerprint = key), ip, clock(), via)
            val idx = list.indexOfFirst { it.fingerprint == key }
            if (idx >= 0) list.toMutableList().also { it[idx] = peer } else list + peer
        }
    }

    /** Drops peers not seen within [maxAgeMs], except fingerprints in [keep]. */
    fun expire(maxAgeMs: Long, keep: Set<String> = emptySet()) {
        val cutoff = clock() - maxAgeMs
        _peers.update { list -> list.filter { it.lastSeen >= cutoff || it.fingerprint in keep } }
    }

    fun clear() = _peers.update { emptyList() }
}
