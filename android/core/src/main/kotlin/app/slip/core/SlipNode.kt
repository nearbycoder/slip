package app.slip.core

import app.slip.core.client.PeerAddress
import app.slip.core.client.Sender
import app.slip.core.client.SlipClient
import app.slip.core.discovery.DiscoveredVia
import app.slip.core.discovery.Discovery
import app.slip.core.discovery.PeerRegistry
import app.slip.core.http.MiniHttpServer
import app.slip.core.identity.Identity
import app.slip.core.model.DeviceInfo
import app.slip.core.model.DeviceType
import app.slip.core.server.ReceiveController
import app.slip.core.server.ReceiveStorage
import app.slip.core.server.ServerConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** User-facing settings that affect the protocol layer. */
data class NodeSettings(
    val alias: String,
    val deviceModel: String? = null,
    val deviceType: DeviceType = DeviceType.DESKTOP,
    val port: Int = SlipConstants.DEFAULT_PORT,
    val https: Boolean = true,
    val autoAccept: Boolean = false,
    val pin: String? = null,
    val discoverable: Boolean = true,
    val multicastGroup: String = SlipConstants.MULTICAST_GROUP,
    val multicastPort: Int = SlipConstants.MULTICAST_PORT,
    /** Whether to run the multicast listener at all (tests turn it off). */
    val multicast: Boolean = true,
)

sealed interface ServerState {
    data object Stopped : ServerState
    data class Running(val port: Int, val https: Boolean) : ServerState
    data class Failed(val message: String) : ServerState
}

/**
 * One Slip endpoint: identity + receiving server + discovery + sender, wired together. Both the Android service and
 * the JVM CLI drive this; it owns no UI.
 */
class SlipNode(
    val identity: Identity,
    initialSettings: NodeSettings,
    private val storage: () -> ReceiveStorage,
    val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val log: (String) -> Unit = {},
) {
    private val _settings = MutableStateFlow(initialSettings)
    val settings: StateFlow<NodeSettings> = _settings.asStateFlow()

    private val _server = MutableStateFlow<ServerState>(ServerState.Stopped)
    val server: StateFlow<ServerState> = _server.asStateFlow()

    val client = SlipClient()
    val peers = PeerRegistry()
    val sender = Sender(client, ::deviceInfo, scope)
    val receiver = ReceiveController(
        config = { _settings.value.let { ServerConfig(deviceInfo(), it.pin?.takeIf(String::isNotEmpty), it.autoAccept) } },
        storage = storage,
        onPeer = { info, ip -> peers.upsert(info, ip, DiscoveredVia.REGISTER) },
        log = log,
    )

    private var httpServer: MiniHttpServer? = null
    private var discovery: Discovery? = null

    fun deviceInfo(): DeviceInfo {
        val s = _settings.value
        val port = (server.value as? ServerState.Running)?.port ?: s.port
        return DeviceInfo(
            alias = s.alias,
            version = SlipConstants.PROTOCOL_VERSION,
            deviceModel = s.deviceModel,
            deviceType = s.deviceType.wire,
            fingerprint = identity.fingerprint(s.https),
            port = port,
            protocol = if (s.https) "https" else "http",
            download = false,
        )
    }

    @Synchronized
    fun start() {
        startServer()
        startDiscovery()
    }

    @Synchronized
    fun stop() {
        discovery?.stop()
        discovery = null
        httpServer?.stop()
        httpServer = null
        _server.value = ServerState.Stopped
    }

    /** Applies new settings, restarting the server/discovery only when their parameters changed. */
    @Synchronized
    fun updateSettings(newSettings: NodeSettings) {
        val old = _settings.value
        _settings.value = newSettings
        val running = httpServer != null
        if (!running) return
        if (old.port != newSettings.port || old.https != newSettings.https) {
            httpServer?.stop(); httpServer = null
            startServer()
        }
        if (old.multicastGroup != newSettings.multicastGroup || old.multicastPort != newSettings.multicastPort || old.multicast != newSettings.multicast) {
            discovery?.stop(); discovery = null
            startDiscovery()
        } else if (old.alias != newSettings.alias || old.https != newSettings.https || old.port != newSettings.port ||
            (!old.discoverable && newSettings.discoverable)
        ) {
            discovery?.announce()
        }
    }

    private fun startServer() {
        val s = _settings.value
        val server = MiniHttpServer(s.port, if (s.https) identity.serverSslContext() else null, receiver)
        try {
            val port = server.start()
            httpServer = server
            _server.value = ServerState.Running(port, s.https)
            log("server: listening on ${if (s.https) "https" else "http"}://0.0.0.0:$port")
        } catch (e: Exception) {
            _server.value = ServerState.Failed("Port ${s.port}: ${e.message}")
            log("server: failed to bind ${s.port}: ${e.message}")
        }
    }

    private fun startDiscovery() {
        val s = _settings.value
        if (!s.multicast) return
        val d = Discovery(
            ourInfo = ::deviceInfo,
            client = client,
            registry = peers,
            discoverable = { _settings.value.discoverable },
            activeFingerprints = { activeFingerprints() },
            groupAddress = s.multicastGroup,
            multicastPort = s.multicastPort,
            log = log,
        )
        try {
            d.start()
            discovery = d
            d.announce()
        } catch (e: Exception) {
            log("multicast: failed to start: ${e.message}")
        }
    }

    private fun activeFingerprints(): Set<String> {
        val out = HashSet<String>()
        receiver.session.value?.takeIf { it.isActive }?.let { out += it.sender.fingerprint }
        return out
    }

    /** Announce again, and fall back to an HTTP scan if nobody shows up within a few seconds. */
    fun refresh(forceScan: Boolean = false) {
        discovery?.announce()
        scope.launch {
            if (!forceScan) delay(3_000)
            if (forceScan || peers.peers.value.isEmpty()) scan()
        }
    }

    suspend fun scan() {
        val d = discovery ?: Discovery(::deviceInfo, client, peers, log = log)
        d.scan(_settings.value.port)
    }

    fun onNetworkChanged() {
        discovery?.rejoin()
        discovery?.announce()
    }

    /** Resolve a manually-entered address via `/info` (then `/register`) and add it as a peer. */
    suspend fun addManualPeer(address: PeerAddress) = runCatching {
        val info = runCatching { client.register(address, deviceInfo(), 3_000) }.getOrElse { client.info(address) }
        val fixed = info.copy(port = address.port, protocol = address.protocol.wire)
        peers.upsert(fixed, address.host, DiscoveredVia.MANUAL)
        fixed
    }
}
