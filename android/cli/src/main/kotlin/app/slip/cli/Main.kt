package app.slip.cli

import app.slip.core.NodeSettings
import app.slip.core.ServerState
import app.slip.core.SlipConstants
import app.slip.core.SlipNode
import app.slip.core.client.FileSource
import app.slip.core.client.PeerAddress
import app.slip.core.client.SendStatus
import app.slip.core.identity.Aliases
import app.slip.core.identity.FileIdentityStore
import app.slip.core.model.DeviceType
import app.slip.core.model.Protocol
import app.slip.core.model.SlipJson
import app.slip.core.model.DeviceInfo
import app.slip.core.server.Decision
import app.slip.core.server.DirectoryStorage
import app.slip.core.server.FileStatus
import app.slip.core.server.SessionStatus
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.system.exitProcess

private const val USAGE = """slip-cli — Slip (LocalSend v2) JVM core harness

Usage:
  slip-cli receive  [--port P] [--dir D] [--auto-accept] [--http] [--pin PIN] [--alias A] [--no-multicast]
  slip-cli send     --to host:port [--http] [--pin PIN] [--text MESSAGE] [files/folders…]
  slip-cli discover [--seconds N] [--port P] [--http] [--scan]
  slip-cli info     --to host:port [--http]
  slip-cli register --to host:port [--http] [--port P]

Common:
  --state DIR   where identity is stored (default ~/.config/slip-jvm-cli)
  --verbose     log discovery/server internals
"""

class Args(raw: Array<String>) {
    val command: String? = raw.firstOrNull()
    private val flags = HashMap<String, String?>()
    val positional = ArrayList<String>()
    private val valued = setOf("--port", "--dir", "--pin", "--alias", "--to", "--text", "--seconds", "--state")

    init {
        var i = 1
        while (i < raw.size) {
            val a = raw[i]
            if (a.startsWith("--")) {
                val eq = a.indexOf('=')
                if (eq > 0) flags[a.substring(0, eq)] = a.substring(eq + 1)
                else if (a in valued) { flags[a] = raw.getOrNull(i + 1) ?: die("$a needs a value"); i++ }
                else flags[a] = null
            } else positional += a
            i++
        }
    }

    fun has(name: String) = flags.containsKey(name)
    fun value(name: String): String? = flags[name]
    fun int(name: String, default: Int) = value(name)?.toIntOrNull() ?: default
}

fun die(msg: String): Nothing {
    System.err.println("error: $msg")
    exitProcess(2)
}

fun main(raw: Array<String>) {
    val args = Args(raw)
    when (args.command) {
        "receive" -> receive(args)
        "send" -> send(args)
        "discover" -> discover(args)
        "info" -> info(args)
        "register" -> register(args)
        null, "help", "--help", "-h" -> print(USAGE)
        else -> die("unknown command '${args.command}'\n$USAGE")
    }
    exitProcess(0)
}

private fun makeNode(args: Args, port: Int, dir: File = File("."), multicast: Boolean = true): SlipNode {
    val stateDir = File(args.value("--state") ?: (System.getProperty("user.home") + "/.config/slip-jvm-cli"))
    val identity = FileIdentityStore(stateDir).loadOrCreate()
    val aliasFile = File(stateDir, "alias")
    val alias = args.value("--alias") ?: aliasFile.takeIf { it.isFile }?.readText()?.trim()?.ifEmpty { null }
        ?: Aliases.generate().also { aliasFile.writeText(it) }
    val verbose = args.has("--verbose")
    return SlipNode(
        identity,
        NodeSettings(
            alias = alias,
            deviceModel = "Slip CLI",
            deviceType = DeviceType.HEADLESS,
            port = port,
            https = !args.has("--http"),
            autoAccept = args.has("--auto-accept"),
            pin = args.value("--pin"),
            discoverable = true,
            multicast = multicast && !args.has("--no-multicast"),
        ),
        storage = { DirectoryStorage(dir) },
        log = { if (verbose) System.err.println("[slip] $it") },
    )
}

private fun human(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "%.1f KiB".format(bytes / 1024.0)
    bytes < 1024L * 1024 * 1024 -> "%.1f MiB".format(bytes / 1024.0 / 1024)
    else -> "%.2f GiB".format(bytes / 1024.0 / 1024 / 1024)
}

private fun receive(args: Args) = runBlocking {
    val dir = File(args.value("--dir") ?: ".").absoluteFile.apply { mkdirs() }
    val node = makeNode(args, args.int("--port", SlipConstants.DEFAULT_PORT), dir)
    node.start()
    val st = node.server.value
    if (st !is ServerState.Running) die("server failed: $st")
    val info = node.deviceInfo()
    println("Receiving as \"${info.alias}\" on ${info.protocol}://0.0.0.0:${st.port} → $dir")
    println("fingerprint ${info.fingerprint}")
    println(if (args.has("--auto-accept")) "auto-accept on" else "will prompt for each transfer (y/n)")

    launch {
        node.receiver.messages.collect { m -> println("message from ${m.sender.alias} (${m.senderIp}):\n${m.text}") }
    }
    launch {
        node.receiver.pending.filterNotNull().collect { req ->
            println("incoming from ${req.sender.alias} (${req.senderIp}, ${req.sender.deviceModel ?: req.sender.type.wire}): " +
                "${req.files.size} file(s), ${human(req.totalSize)}")
            req.files.forEach { println("  - ${it.fileName} (${human(it.size)})") }
            print("accept? [y/N] ")
            System.out.flush()
            val answer = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { readlnOrNull() }
            node.receiver.respond(if (answer?.trim()?.lowercase()?.startsWith("y") == true) Decision.Accept() else Decision.Decline)
        }
    }
    launch {
        var lastId: String? = null
        var lastReported = HashSet<String>()
        node.receiver.session.filterNotNull().collect { s ->
            if (s.id != lastId) { lastId = s.id; lastReported = HashSet() }
            s.files.values.filter { it.status == FileStatus.DONE || it.status == FileStatus.FAILED }.forEach { f ->
                if (lastReported.add(f.dto.id)) {
                    if (f.status == FileStatus.DONE) println("saved ${f.saved?.relativePath} (${human(f.bytes)})")
                    else println("failed ${f.dto.fileName}: ${f.error}")
                }
            }
            if (!s.isActive && s.status != SessionStatus.AWAITING && lastReported.add("#end")) {
                println("session ${s.status.name.lowercase()} — ${human(s.receivedBytes)} from ${s.sender.alias}")
            }
        }
    }
    // run until killed
    while (true) delay(60_000)
}

private fun target(args: Args): PeerAddress {
    val to = args.value("--to") ?: die("--to host:port is required")
    return PeerAddress.parse(to, if (args.has("--http")) Protocol.HTTP else Protocol.HTTPS)
}

private fun send(args: Args) = runBlocking {
    val addr = target(args)
    val node = makeNode(args, args.int("--port", SlipConstants.DEFAULT_PORT), multicast = false)
    val text = args.value("--text")
    val sources = args.positional.flatMap { p ->
        val f = File(p)
        if (!f.exists()) die("no such file: $p")
        FileSource.expand(f)
    }
    if (text == null && sources.isEmpty()) die("nothing to send")
    val pin = args.value("--pin")
    val job = if (text != null) node.sender.sendText(addr, text) { attempt -> if (attempt == 1) pin else null }
    else node.sender.send(addr, sources) { attempt -> if (attempt == 1) pin else null }
    println("sending ${if (text != null) "text" else "${sources.size} file(s), ${human(sources.sumOf { it.size })}"} to $addr")
    val progress = launch {
        var last = -1L
        job.state.collectLatest { s ->
            if (s.status == SendStatus.SENDING && s.sentBytes != last) {
                last = s.sentBytes
                System.err.print("\r${human(s.sentBytes)} / ${human(s.totalBytes)}  ${human(s.speed())}/s   ")
                delay(250)
            }
        }
    }
    val result = job.await()
    progress.cancel()
    System.err.println()
    result.files.forEach { println("  ${it.status.name.lowercase().padEnd(9)} ${it.fileName} (${human(it.sent)})${it.error?.let { e -> " — $e" } ?: ""}") }
    println("result: ${result.status.name.lowercase()}${result.error?.let { " ($it)" } ?: ""}")
    if (result.status != SendStatus.DONE) exitProcess(1)
}

private fun discover(args: Args) = runBlocking {
    val seconds = args.int("--seconds", 5)
    val node = makeNode(args, args.int("--port", SlipConstants.DEFAULT_PORT))
    node.start()
    if (node.server.value !is ServerState.Running) {
        System.err.println("note: HTTP server could not bind (${node.server.value}); relying on multicast replies only")
    }
    println("discovering for ${seconds}s as \"${node.deviceInfo().alias}\" (${node.deviceInfo().protocol}, port ${node.deviceInfo().port})…")
    if (args.has("--scan")) launch { node.scan() }
    delay(seconds * 1000L)
    val peers = node.peers.peers.value
    if (peers.isEmpty()) println("no peers found")
    peers.forEach { p ->
        println("${p.info.alias.padEnd(20)} ${p.ip}:${p.info.port} ${p.info.protocol.padEnd(5)} ${(p.info.deviceModel ?: "-").padEnd(12)} ${p.info.type.wire.padEnd(8)} via ${p.via.name.lowercase()}  fp=${p.fingerprint.take(16)}…")
    }
    node.stop()
}

private fun info(args: Args) = runBlocking {
    val node = makeNode(args, SlipConstants.DEFAULT_PORT, multicast = false)
    val info = node.client.info(target(args))
    println(SlipJson.encodeToString(DeviceInfo.serializer(), info))
}

private fun register(args: Args) = runBlocking {
    val node = makeNode(args, args.int("--port", SlipConstants.DEFAULT_PORT), multicast = false)
    val ours = node.deviceInfo()
    println("POST /register as ${SlipJson.encodeToString(DeviceInfo.serializer(), ours)}")
    val info = node.client.register(target(args), ours)
    println("200 ${SlipJson.encodeToString(DeviceInfo.serializer(), info)}")
}
