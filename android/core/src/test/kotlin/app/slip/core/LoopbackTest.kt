package app.slip.core

import app.slip.core.client.FileSource
import app.slip.core.client.HttpStatusException
import app.slip.core.client.PeerAddress
import app.slip.core.client.PrepareResult
import app.slip.core.client.SendStatus
import app.slip.core.client.SendSource
import app.slip.core.identity.Identity
import app.slip.core.model.DeviceInfo
import app.slip.core.model.DeviceType
import app.slip.core.model.FileDto
import app.slip.core.model.PrepareUploadRequest
import app.slip.core.model.Protocol
import app.slip.core.server.Decision
import app.slip.core.server.DirectoryStorage
import app.slip.core.ServerState
import app.slip.core.server.SessionStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.random.Random

class LoopbackTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val tmp = Files.createTempDirectory("slip-loopback").toFile()
    private val nodes = mutableListOf<SlipNode>()

    companion object {
        // RSA keygen is slow-ish; share identities across tests.
        val receiverId by lazy { Identity.generate() }
        val senderId by lazy { Identity.generate() }
    }

    @After
    fun tearDown() {
        nodes.forEach { it.stop() }
        scope.cancel()
        tmp.deleteRecursively()
    }

    private fun receiver(https: Boolean, autoAccept: Boolean = true, pin: String? = null): Pair<SlipNode, File> {
        val dir = File(tmp, "recv-${nodes.size}").apply { mkdirs() }
        val node = SlipNode(
            receiverId,
            NodeSettings("Receiver", "JVM", DeviceType.HEADLESS, port = 0, https = https, autoAccept = autoAccept, pin = pin, multicast = false),
            storage = { DirectoryStorage(dir) },
            scope = scope,
        )
        node.start()
        assertTrue(node.server.value is ServerState.Running)
        nodes += node
        return node to dir
    }

    private fun senderNode(): SlipNode = SlipNode(
        senderId,
        NodeSettings("Sender", "JVM", DeviceType.HEADLESS, port = 0, multicast = false),
        storage = { DirectoryStorage(tmp) },
        scope = scope,
    ).also { nodes += it }

    private fun addressOf(node: SlipNode, https: Boolean) =
        PeerAddress("127.0.0.1", (node.server.value as ServerState.Running).port, if (https) Protocol.HTTPS else Protocol.HTTP)

    private fun randomFile(name: String, size: Int): File {
        val f = File(tmp, name)
        f.parentFile.mkdirs()
        f.writeBytes(Random(size).nextBytes(size))
        return f
    }

    private fun sendFilesAndVerify(https: Boolean) = runBlocking {
        val (recv, dir) = receiver(https)
        val sender = senderNode()
        val big = randomFile("src/big.bin", 5 * 1024 * 1024 + 123)
        val small = randomFile("src/folder/sub/small.txt", 17)
        val empty = randomFile("src/empty.dat", 0)
        val sources = listOf(FileSource(big), FileSource(small, "folder/sub/small.txt"), FileSource(empty))
        val job = sender.sender.send(addressOf(recv, https), sources)
        val state = withTimeout(30_000) { job.await() }
        assertEquals(state.error, SendStatus.DONE, state.status)
        assertEquals(big.length() + 17, state.sentBytes)
        assertArrayEquals(big.readBytes(), File(dir, "big.bin").readBytes())
        assertArrayEquals(small.readBytes(), File(dir, "folder/sub/small.txt").readBytes())
        assertEquals(0, File(dir, "empty.dat").length())
        assertTrue(dir.walk().none { it.name.startsWith(".slip-partial-") })
        val session = recv.receiver.history.value.first()
        assertEquals(SessionStatus.FINISHED, session.status)
        assertEquals("Sender", session.sender.alias)
        // the sender registered itself as a peer via prepare-upload
        assertTrue(recv.peers.peers.value.any { it.info.alias == "Sender" })

        // Sending the same file again produces "big (1).bin".
        assertEquals(SendStatus.DONE, sender.sender.send(addressOf(recv, https), listOf(FileSource(big))).await().status)
        assertArrayEquals(big.readBytes(), File(dir, "big (1).bin").readBytes())
    }

    @Test fun sendOverHttps() = sendFilesAndVerify(https = true)

    @Test fun sendOverHttp() = sendFilesAndVerify(https = false)

    @Test
    fun infoAndRegister() = runBlocking {
        val (recv, _) = receiver(https = true)
        val sender = senderNode()
        val addr = addressOf(recv, true)
        val info = sender.client.info(addr)
        assertEquals("Receiver", info.alias)
        assertEquals(receiverId.certFingerprint, info.fingerprint)
        assertEquals("2.1", info.version)
        assertEquals("https", info.protocol)
        val reg = sender.client.register(addr, sender.deviceInfo())
        assertEquals("Receiver", reg.alias)
        val peer = recv.peers.peers.value.single()
        assertEquals("127.0.0.1", peer.ip)
        assertEquals(senderId.certFingerprint, peer.fingerprint)

        // v1 and unknown routes are 404
        val http = app.slip.core.client.SlipClient.defaultOkHttp()
        val code = http.newCall(Request.Builder().url("https://127.0.0.1:${addr.port}/api/localsend/v1/info").build()).execute().use { it.code }
        assertEquals(404, code)
    }

    @Test
    fun registerThenSendOnKeepAliveConnection() = runBlocking {
        for (https in listOf(true, false)) {
            val (recv, dir) = receiver(https)
            val sender = senderNode()
            val addr = addressOf(recv, https)
            sender.client.register(addr, sender.deviceInfo(), 3_000)
            assertEquals(SendStatus.DONE, sender.sender.sendText(addr, "after register").await().status)
            sender.client.info(addr)
            val f = randomFile("ka-$https.bin", 3000)
            assertEquals(SendStatus.DONE, sender.sender.send(addr, listOf(FileSource(f))).await().status)
            assertArrayEquals(f.readBytes(), File(dir, f.name).readBytes())
        }
    }

    @Test
    fun pinRequired() = runBlocking {
        val (recv, dir) = receiver(https = true, pin = "1234")
        val sender = senderNode()
        val file = randomFile("pin.bin", 1000)
        val addr = addressOf(recv, true)

        val req = PrepareUploadRequest(sender.deviceInfo(), mapOf("f" to FileDto("f", "pin.bin", 1000)))
        assertEquals(PrepareResult.PinRequired, sender.client.prepareUpload(addr, req))
        assertEquals(PrepareResult.PinRequired, sender.client.prepareUpload(addr, req, "0000"))

        val noPin = sender.sender.send(addr, listOf(FileSource(file))).await()
        assertEquals(SendStatus.PIN_REQUIRED, noPin.status)

        val attempts = mutableListOf<Int>()
        val ok = sender.sender.send(addr, listOf(FileSource(file))) { attempt ->
            attempts += attempt
            if (attempt == 1) "9999" else "1234"
        }.await()
        assertEquals(SendStatus.DONE, ok.status)
        assertEquals(listOf(1, 2), attempts)
        assertArrayEquals(file.readBytes(), File(dir, "pin.bin").readBytes())
    }

    @Test
    fun declineAndBusy() = runBlocking {
        val (recv, _) = receiver(https = false, autoAccept = false)
        val sender = senderNode()
        val addr = addressOf(recv, false)
        val file = randomFile("d.bin", 10)

        // First request waits for a decision; a second one meanwhile is 409.
        val first = sender.sender.send(addr, listOf(FileSource(file)))
        val pending = withTimeout(10_000) { recv.receiver.pending.filterNotNull().first() }
        assertEquals("Sender", pending.sender.alias)
        assertEquals(10, pending.totalSize)
        val busy = sender.sender.send(addr, listOf(FileSource(file))).await()
        assertEquals(SendStatus.BUSY, busy.status)

        recv.receiver.respond(Decision.Decline)
        assertEquals(SendStatus.DECLINED, first.await().status)
        assertEquals(SessionStatus.DECLINED, recv.receiver.session.value!!.status)

        // Accept a subset: only the accepted file is uploaded, the other is skipped.
        val other = randomFile("e.bin", 20)
        val partial = sender.sender.send(addr, listOf(FileSource(file), FileSource(other)))
        val p2 = withTimeout(10_000) { recv.receiver.pending.filterNotNull().first() }
        val keep = p2.files.first { it.fileName == "e.bin" }.id
        recv.receiver.respond(Decision.Accept(setOf(keep)))
        val result = partial.await()
        assertEquals(SendStatus.DONE, result.status)
        assertEquals(20, result.sentBytes)
    }

    @Test
    fun decisionTimeoutIs403() = runBlocking {
        val dir = File(tmp, "timeout").apply { mkdirs() }
        val controller = app.slip.core.server.ReceiveController(
            config = { app.slip.core.server.ServerConfig(DeviceInfo("R", fingerprint = "r")) },
            storage = { DirectoryStorage(dir) },
            decisionTimeoutMs = 300,
        )
        val server = app.slip.core.http.MiniHttpServer(0, null, controller)
        val port = server.start()
        try {
            val client = app.slip.core.client.SlipClient()
            val req = PrepareUploadRequest(DeviceInfo("S", fingerprint = "s"), mapOf("f" to FileDto("f", "a", 1)))
            assertEquals(PrepareResult.Declined, client.prepareUpload(PeerAddress("127.0.0.1", port, Protocol.HTTP), req))
        } finally {
            server.stop()
        }
    }

    @Test
    fun textMessageIs204() = runBlocking {
        val (recv, dir) = receiver(https = true, autoAccept = false)
        val sender = senderNode()
        val message = async { withTimeout(10_000) { recv.receiver.messages.first() } }
        Thread.sleep(100)
        val state = sender.sender.sendText(addressOf(recv, true), "Hello, Slip! ✓").await()
        assertEquals(SendStatus.DONE, state.status)
        assertEquals("Hello, Slip! ✓", message.await().text)
        assertEquals(0, dir.listFiles()!!.size)
    }

    @Test
    fun uploadErrors() = runBlocking {
        val (recv, dir) = receiver(https = false)
        val sender = senderNode()
        val addr = addressOf(recv, false)
        val content = "hello world".toByteArray()
        val goodHash = MessageDigest.getInstance("SHA-256").digest(content).joinToString("") { "%02x".format(it) }
        val req = PrepareUploadRequest(sender.deviceInfo(), mapOf(
            "good" to FileDto("good", "good.txt", content.size.toLong(), "text/plain", sha256 = goodHash),
            "bad" to FileDto("bad", "bad.txt", content.size.toLong(), "text/plain", sha256 = "00".repeat(32)),
        ))
        val accepted = (sender.client.prepareUpload(addr, req) as PrepareResult.Accepted).response
        val source = object : SendSource {
            override val fileName = "x"
            override val size = content.size.toLong()
            override val mimeType = "text/plain"
            override fun open() = ByteArrayInputStream(content)
        }
        fun expectCode(code: Int, block: suspend () -> Unit) = runBlocking {
            try { block(); fail("expected $code") } catch (e: HttpStatusException) { assertEquals(code, e.code) }
        }
        expectCode(403) { sender.client.upload(addr, accepted.sessionId, "good", "wrong-token", source) }
        expectCode(403) { sender.client.upload(addr, "no-such-session", "good", accepted.files["good"]!!, source) }
        expectCode(422) { sender.client.upload(addr, accepted.sessionId, "bad", accepted.files["bad"]!!, source) }
        sender.client.upload(addr, accepted.sessionId, "good", accepted.files["good"]!!, source)
        assertArrayEquals(content, File(dir, "good.txt").readBytes())
        assertTrue(!File(dir, "bad.txt").exists())
        assertTrue(dir.listFiles()!!.none { it.name.startsWith(".slip-partial-") })

        val http = OkHttpClient()
        val missing = http.newCall(
            Request.Builder().url("http://127.0.0.1:${addr.port}/api/localsend/v2/upload?sessionId=x")
                .post(ByteArray(0).toRequestBody(null)).build(),
        ).execute().use { it.code }
        assertEquals(400, missing)
    }

    @Test
    fun cancelBySender() = runBlocking {
        val (recv, dir) = receiver(https = false)
        val sender = senderNode()
        val addr = addressOf(recv, false)
        // A slow, endless source so we can cancel mid-upload.
        val slow = object : SendSource {
            override val fileName = "slow.bin"
            override val size = 50L * 1024 * 1024
            override val mimeType = "application/octet-stream"
            override fun open() = object : java.io.InputStream() {
                override fun read(): Int = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int { Thread.sleep(5); java.util.Arrays.fill(b, off, off + minOf(len, 4096), 7); return minOf(len, 4096) }
            }
        }
        val job = sender.sender.send(addr, listOf(slow))
        withTimeout(10_000) { job.state.first { it.sentBytes > 0 } }
        job.cancel()
        assertEquals(SendStatus.CANCELLED, job.await().status)
        withTimeout(10_000) { recv.receiver.session.first { it?.status == SessionStatus.CANCELLED } }
        // partial file removed
        withTimeout(10_000) { while (dir.walk().any { it.isFile }) kotlinx.coroutines.delay(50) }
    }
}
