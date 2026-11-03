package app.slip.core.discovery

import app.slip.core.SlipConstants
import app.slip.core.client.PeerAddress
import app.slip.core.client.SlipClient
import app.slip.core.model.DeviceInfo
import app.slip.core.model.MulticastMessage
import app.slip.core.model.Protocol
import app.slip.core.model.SlipJson
import app.slip.core.net.NetworkUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.SocketException
import java.net.StandardSocketOptions
import java.net.ConnectException
import javax.net.ssl.SSLException

/**
 * LocalSend discovery: a multicast listener/announcer plus the HTTP `/register` scan fallback.
 *
 * Everything that knows "who we are" is read through [ourInfo] at the time of use, so alias/port changes take effect
 * without a restart.
 */
class Discovery(
    private val ourInfo: () -> DeviceInfo,
    private val client: SlipClient,
    private val registry: PeerRegistry,
    private val discoverable: () -> Boolean = { true },
    private val activeFingerprints: () -> Set<String> = { emptySet() },
    private val groupAddress: String = SlipConstants.MULTICAST_GROUP,
    private val multicastPort: Int = SlipConstants.MULTICAST_PORT,
    private val log: (String) -> Unit = {},
) {
    private var socket: MulticastSocket? = null
    private var scope: CoroutineScope? = null
    private val group: InetAddress = InetAddress.getByName(groupAddress)

    val isRunning: Boolean get() = socket != null

    @Synchronized
    fun start() {
        if (socket != null) return
        val s = scope ?: CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scope = it }
        val sock = openSocket()
        socket = sock
        s.launch { receiveLoop(sock) }
        s.launch {
            var sinceAnnounce = 0L
            while (isActive) {
                delay(5_000)
                sinceAnnounce += 5_000
                // Peers only announce at startup, so ask again periodically; their /register replies refresh them.
                if (sinceAnnounce >= SlipConstants.REANNOUNCE_INTERVAL_MS) {
                    sinceAnnounce = 0
                    if (discoverable()) send(announce = true)
                }
                expireStale()
            }
        }
    }

    @Synchronized
    fun stop() {
        runCatching { socket?.close() }
        socket = null
        scope?.cancel()
        scope = null
    }

    /** Re-joins the group on the current interfaces (call on network change). */
    @Synchronized
    fun rejoin() {
        val sock = socket ?: return
        joinAll(sock)
    }

    private fun openSocket(): MulticastSocket {
        fun configure(sock: MulticastSocket) {
            sock.reuseAddress = true
            runCatching { sock.setOption(StandardSocketOptions.SO_REUSEPORT, true) }
        }
        val sock = try {
            MulticastSocket(null as java.net.SocketAddress?).also {
                configure(it)
                it.bind(InetSocketAddress(multicastPort))
            }
        } catch (e: Exception) {
            log("multicast: bind 0.0.0.0:$multicastPort failed (${e.message}), binding the group address instead")
            MulticastSocket(null as java.net.SocketAddress?).also {
                configure(it)
                it.bind(InetSocketAddress(group, multicastPort))
            }
        }
        sock.timeToLive = SlipConstants.MULTICAST_TTL
        runCatching { sock.setOption(StandardSocketOptions.IP_MULTICAST_LOOP, true) }
            .onFailure { @Suppress("DEPRECATION") runCatching { sock.loopbackMode = false } }
        joinAll(sock)
        return sock
    }

    private fun joinAll(sock: MulticastSocket) {
        val interfaces = NetworkUtil.multicastInterfaces()
        var joined = 0
        for (ni in interfaces) {
            try {
                sock.joinGroup(InetSocketAddress(group, 0), ni)
                joined++
            } catch (e: Exception) {
                // already joined, or the interface can't do multicast
            }
        }
        if (joined == 0) {
            @Suppress("DEPRECATION") runCatching { sock.joinGroup(group) }
        }
        log("multicast: joined $groupAddress on ${interfaces.joinToString { it.name }.ifEmpty { "default" }}")
    }

    private fun receiveLoop(sock: MulticastSocket) {
        val buf = ByteArray(64 * 1024)
        while (!sock.isClosed) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                sock.receive(packet)
            } catch (e: SocketException) {
                if (sock.isClosed) return else continue
            } catch (e: Exception) {
                continue
            }
            val ip = packet.address?.hostAddress ?: continue
            val text = String(packet.data, packet.offset, packet.length, Charsets.UTF_8)
            val msg = runCatching { SlipJson.decodeFromString(MulticastMessage.serializer(), text) }.getOrNull() ?: continue
            onMessage(msg, ip)
        }
    }

    internal fun onMessage(msg: MulticastMessage, ip: String) {
        val ours = ourInfo()
        if (msg.fingerprint.isEmpty() || msg.fingerprint == ours.fingerprint) return
        val info = msg.toDeviceInfo()
        registry.upsert(info, ip, DiscoveredVia.MULTICAST)
        if (msg.isAnnounce && discoverable()) {
            scope?.launch {
                try {
                    client.register(PeerAddress.of(info, ip), ourInfo(), timeoutMs = 3_000)
                } catch (e: Exception) {
                    log("register -> $ip failed (${e.message}); answering via multicast")
                    send(announce = false)
                }
            }
        }
    }

    /**
     * Drops peers not seen within [maxAgeMs], but only after a direct `/register` probe also fails; peers that answer
     * are refreshed under their original fingerprint/port/protocol. Peers with an active transfer are never touched.
     */
    internal suspend fun expireStale(
        maxAgeMs: Long = SlipConstants.PEER_EXPIRY_MS,
        timeoutMs: Long = SlipConstants.PEER_PROBE_TIMEOUT_MS,
    ) = coroutineScope {
        for (peer in registry.stale(maxAgeMs, activeFingerprints())) {
            launch(Dispatchers.IO) {
                val reply = runCatching { client.register(peer.address, ourInfo(), timeoutMs) }.getOrNull()
                if (reply != null) {
                    val fresh = reply.copy(fingerprint = peer.fingerprint, port = peer.info.port, protocol = peer.info.protocol)
                    registry.upsert(fresh, peer.ip, peer.via)
                } else {
                    log("peer ${peer.info.alias} (${peer.address}) is gone")
                    registry.remove(peer)
                }
            }
        }
    }

    /** Sends our announcement three times (~100 ms, ~500 ms, ~2 s) since UDP packets get dropped. */
    fun announce() {
        if (!discoverable()) return
        scope?.launch {
            for (wait in longArrayOf(100, 400, 1500)) {
                delay(wait)
                send(announce = true)
            }
        }
    }

    private fun send(announce: Boolean) {
        val sock = socket ?: return
        val bytes = SlipJson.encodeToString(MulticastMessage.serializer(), MulticastMessage.from(ourInfo(), announce)).toByteArray()
        val packet = DatagramPacket(bytes, bytes.size, group, multicastPort)
        val interfaces = NetworkUtil.multicastInterfaces()
        synchronized(sock) {
            if (interfaces.isEmpty()) {
                runCatching { sock.send(packet) }
            } else {
                for (ni in interfaces) {
                    runCatching {
                        sock.networkInterface = ni
                        sock.send(packet)
                    }.onFailure { log("multicast send on ${ni.name} failed: ${it.message}") }
                }
            }
        }
    }

    /**
     * HTTP fallback: POST /register to every host of each local /24 on [port] (≤ 50 at a time, ~1 s timeout).
     * Tries HTTPS first and falls back to HTTP when the TLS handshake fails.
     */
    suspend fun scan(port: Int = ourInfo().port, timeoutMs: Long = 1_000) = coroutineScope {
        val targets = NetworkUtil.scanTargets()
        val semaphore = Semaphore(50)
        log("scan: ${targets.size} hosts on port $port")
        targets.forEach { addr ->
            launch(Dispatchers.IO) {
                semaphore.withPermit { probe(addr.hostAddress, port, timeoutMs) }
            }
        }
    }

    /** Registers with one host; returns the peer if it answered. */
    suspend fun probe(ip: String, port: Int, timeoutMs: Long = 1_000, preferred: Protocol = Protocol.HTTPS): Peer? {
        val order = if (preferred == Protocol.HTTPS) listOf(Protocol.HTTPS, Protocol.HTTP) else listOf(Protocol.HTTP, Protocol.HTTPS)
        for (proto in order) {
            try {
                val info = client.register(PeerAddress(ip, port, proto), ourInfo(), timeoutMs)
                if (info.fingerprint == ourInfo().fingerprint) return null
                // The register response may omit port/protocol; we know what worked.
                val fixed = info.copy(port = port, protocol = proto.wire)
                registry.upsert(fixed, ip, DiscoveredVia.SCAN)
                return registry.peers.value.firstOrNull { it.fingerprint == fixed.fingerprint.ifEmpty { "$ip:$port" } }
            } catch (e: SSLException) {
                continue
            } catch (e: ConnectException) {
                return null
            } catch (e: java.io.IOException) {
                // HTTP server answering a TLS client usually surfaces as a protocol/SSL error; try the other one.
                if (proto == order.first() && (e.message?.contains("plaintext", true) == true || e.cause is SSLException)) continue
                return null
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    internal val jobScope: CoroutineScope? get() = scope
}
