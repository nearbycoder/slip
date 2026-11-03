package app.slip.core

import app.slip.core.client.SlipClient
import app.slip.core.discovery.DiscoveredVia
import app.slip.core.discovery.Discovery
import app.slip.core.discovery.PeerRegistry
import app.slip.core.identity.Identity
import app.slip.core.model.DeviceInfo
import app.slip.core.model.DeviceType
import app.slip.core.server.DirectoryStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.nio.file.Files

class PeerExpiryTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val tmp = Files.createTempDirectory("slip-expiry").toFile()
    private val identity by lazy { LoopbackTest.receiverId }
    private var receiver: SlipNode? = null

    private var now = 1_000_000L
    private val registry = PeerRegistry { now }
    private val ours = DeviceInfo(alias = "Us", fingerprint = "our-fingerprint", port = 1, protocol = "http")
    private val discovery = Discovery(ourInfo = { ours }, client = SlipClient(), registry = registry)

    @After
    fun tearDown() {
        receiver?.stop()
        scope.cancel()
        tmp.deleteRecursively()
    }

    private fun startReceiver(): Int {
        val node = SlipNode(
            identity,
            NodeSettings("Reachable", "JVM", DeviceType.HEADLESS, port = 0, https = false, multicast = false),
            storage = { DirectoryStorage(tmp) },
            scope = scope,
        )
        node.start()
        receiver = node
        return (node.server.value as ServerState.Running).port
    }

    private fun closedPort(): Int = ServerSocket(0).use { it.localPort }

    @Test
    fun staleReachablePeerIsRefreshedAndKeepsItsKey() = runBlocking {
        val port = startReceiver()
        registry.upsert(DeviceInfo(alias = "Old name", fingerprint = "original-fp", port = port, protocol = "http"), "127.0.0.1", DiscoveredVia.MULTICAST)
        now += SlipConstants.PEER_EXPIRY_MS + 1

        discovery.expireStale(timeoutMs = 2_000)

        val peer = registry.peers.value.single()
        assertEquals("original-fp", peer.fingerprint)
        assertEquals(port, peer.info.port)
        assertEquals("http", peer.info.protocol)
        assertEquals("Reachable", peer.info.alias)
        assertEquals(now, peer.lastSeen)
    }

    @Test
    fun staleUnreachablePeerIsRemoved() = runBlocking {
        val port = closedPort()
        registry.upsert(DeviceInfo(alias = "Gone", fingerprint = "gone", port = port, protocol = "http"), "127.0.0.1", DiscoveredVia.MULTICAST)
        now += SlipConstants.PEER_EXPIRY_MS + 1

        discovery.expireStale(timeoutMs = 500)

        assertTrue(registry.peers.value.isEmpty())
    }

    @Test
    fun freshAndBusyPeersAreNotProbed() = runBlocking {
        val port = closedPort()
        val busy = Discovery(ourInfo = { ours }, client = SlipClient(), registry = registry, activeFingerprints = { setOf("busy") })
        registry.upsert(DeviceInfo(alias = "Busy", fingerprint = "busy", port = port, protocol = "http"), "127.0.0.1", DiscoveredVia.MULTICAST)
        now += SlipConstants.PEER_EXPIRY_MS + 1
        registry.upsert(DeviceInfo(alias = "Fresh", fingerprint = "fresh", port = port, protocol = "http"), "127.0.0.1", DiscoveredVia.MULTICAST)

        busy.expireStale(timeoutMs = 500)

        assertEquals(setOf("busy", "fresh"), registry.peers.value.map { it.fingerprint }.toSet())
    }
}
