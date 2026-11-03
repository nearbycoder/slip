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

/** Nearby peers keyed by fingerprint; silent peers are found with [stale] and probed before removal. */
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

    /** Peers not seen within [maxAgeMs], except fingerprints in [keep]. */
    fun stale(maxAgeMs: Long, keep: Set<String> = emptySet()): List<Peer> {
        val cutoff = clock() - maxAgeMs
        return _peers.value.filter { it.lastSeen < cutoff && it.fingerprint !in keep }
    }

    /** Removes [peer] unless it has been seen again since that snapshot was taken. */
    fun remove(peer: Peer) {
        _peers.update { list -> list.filterNot { it.fingerprint == peer.fingerprint && it.lastSeen <= peer.lastSeen } }
    }

    fun clear() = _peers.update { emptyList() }
}
