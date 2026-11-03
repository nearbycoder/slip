import Foundation
import SlipKit

// slip-cli — headless harness for SlipKit (see protocol/IMPLEMENTATION.md "Interop testing").

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage:
  slip-cli receive [--port P] [--dir D] [--auto-accept] [--http] [--pin PIN] [--alias NAME] [--no-discovery]
  slip-cli send --to HOST[:PORT] [--http] [--pin PIN] [--text MESSAGE] [--sha256] [FILES/FOLDERS…]
  slip-cli discover [--port P] [--http] [--timeout SECONDS] [--scan] [--scan-port P]…
  slip-cli info --to HOST[:PORT] [--http]
  slip-cli register --to HOST[:PORT] [--http] [--port P]

options:
  --identity PATH   identity file (default: ~/Library/Application Support/Slip/cli-identity.json)
"""

struct Args {
    var command: String
    var flags: Set<String> = []
    var options: [String: [String]] = [:]
    var positional: [String] = []

    static let valued: Set<String> = ["--port", "--dir", "--to", "--pin", "--alias", "--text", "--timeout",
                                      "--identity", "--scan-port"]

    init(_ argv: [String]) {
        command = argv.first ?? "help"
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if Args.valued.contains(a), i + 1 < argv.count {
                options[a, default: []].append(argv[i + 1])
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ k: String) -> String? { options[k]?.last }
    func int(_ k: String) -> Int? { value(k).flatMap(Int.init) }
    func has(_ k: String) -> Bool { flags.contains(k) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    print(message)
}

func loadIdentity(_ args: Args) -> SlipIdentity {
    let url = args.value("--identity").map { URL(fileURLWithPath: $0) }
        ?? SlipIdentity.defaultURL().deletingLastPathComponent().appendingPathComponent("cli-identity.json")
    do { return try SlipIdentity.loadOrCreate(at: url) } catch { fail("identity: \(error)") }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func makeInfo(_ identity: SlipIdentity, args: Args, port: Int, transport: TransportProtocol) -> DeviceInfo {
    DeviceInfo(alias: args.value("--alias") ?? "Slip CLI", deviceModel: DeviceDefaults.deviceModel,
               deviceType: .headless, fingerprint: identity.fingerprint(for: transport), port: port,
               protocol: transport)
}

func installSignalHandlers(_ onExit: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { onExit(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

func peerAddress(_ args: Args) -> PeerAddress {
    guard let to = args.value("--to") else { fail("--to HOST[:PORT] is required") }
    guard let addr = PeerAddress(parsing: to, transport: args.has("--http") ? .http : .https) else { fail("bad --to \(to)") }
    return addr
}

// MARK: - Commands

func receive(_ args: Args) async {
    let identity = loadIdentity(args)
    let port = args.int("--port") ?? SlipConstants.defaultPort
    let transport: TransportProtocol = args.has("--http") ? .http : .https
    let dirPath = ((args.value("--dir") ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
    let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let autoAccept = args.has("--auto-accept")
    let info = makeInfo(identity, args: args, port: port, transport: transport)
    let config = ReceiverConfiguration(port: port, transport: transport, saveDirectory: dir, pin: args.value("--pin"),
                                       autoAccept: autoAccept)
    let server = SlipServer(identity: identity, deviceInfo: info, configuration: config, decide: { req in
        log("incoming request from \(req.sender.alias) (\(req.senderIP)): \(req.files.count) file(s), \(formatBytes(req.totalSize))")
        for f in req.files { log("  - \(f.fileName) (\(formatBytes(f.size)))") }
        print("accept? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = await Task.detached { readLine() }.value
        return answer?.lowercased().hasPrefix("y") == true ? .accept(nil) : .decline
    }, events: { event in
        switch event {
        case .peerRegistered(let p, let ip): log("register: \(p.alias) @ \(ip):\(p.port) (\(p.protocol.rawValue))")
        case .textMessage(let text, let from, _): log("message from \(from.alias): \(text)")
        case .requestWithdrawn: log("request withdrawn")
        case .sessionStarted(let s):
            log("session \(s.sessionId) started: \(s.files.count) file(s) from \(s.sender.alias) -> \(s.saveDirectory.path)")
        case .fileProgress: break
        case .fileFinished(_, _, let url): log("received \(url.path)")
        case .fileFailed(_, let fid, let reason): log("failed \(fid): \(reason)")
        case .sessionFinished(let sid, let cancelled): log("session \(sid) \(cancelled ? "cancelled" : "finished")")
        }
    })
    do {
        let bound = try await server.start()
        log("listening on \(transport.rawValue)://0.0.0.0:\(bound) as \"\(info.alias)\" fingerprint \(server.deviceInfo.fingerprint)")
        log("saving to \(dir.path)\(autoAccept ? " (auto-accept)" : "")")
    } catch {
        fail("\(error.localizedDescription)")
    }
    var discovery: DiscoveryService?
    if !args.has("--no-discovery") {
        let d = DiscoveryService(client: SlipClient(), info: { server.deviceInfo }) { peer, source in
            log("peer (\(source.rawValue)): \(peer.info.alias) @ \(peer.address)")
        }
        do {
            try await d.start()
            d.announce()
            discovery = d
        } catch {
            log("multicast unavailable: \(error)")
        }
    }
    installSignalHandlers { discovery?.stop() }
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

func send(_ args: Args) async {
    let identity = loadIdentity(args)
    let target = peerAddress(args)
    var items: [SendItem] = []
    if let text = args.value("--text") { items.append(.text(text)) }
    do {
        items += try SendItem.items(for: args.positional.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
    } catch {
        fail("\(error.localizedDescription)")
    }
    guard !items.isEmpty else { fail("nothing to send") }
    let info = makeInfo(identity, args: args, port: SlipConstants.defaultPort, transport: target.transport)
    var sender = SlipSender()
    sender.includeSHA256 = args.has("--sha256")
    let total = items.reduce(Int64(0)) { $0 + $1.size }
    log("sending \(items.count) item(s), \(formatBytes(total)) to \(target)")
    let progress = ProgressPrinter(total: total)
    let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.fileName) })
    let outcome = await sender.send(items, to: target, as: info, pin: args.value("--pin")) { event in
        switch event {
        case .waitingForAcceptance: log("waiting for receiver to accept…")
        case .accepted(let sid, let ids): log("accepted: session \(sid), \(ids.count) file(s)")
        case .fileProgress(let id, let sent, _): progress.update(id, sent)
        case .fileFinished(let id): log("uploaded \(names[id] ?? id)")
        case .fileFailed(let id, let reason): log("failed \(names[id] ?? id): \(reason)")
        }
    }
    log("result: \(outcome.message)")
    exit(outcome == .completed || outcome == .delivered ? 0 : 2)
}

final class ProgressPrinter: @unchecked Sendable {
    let total: Int64
    private var sent: [String: Int64] = [:]
    private var lastPercent = -1
    private let lock = NSLock()
    init(total: Int64) { self.total = total }

    func update(_ id: String, _ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        sent[id] = bytes
        guard total > 0 else { return }
        let pct = Int(Double(sent.values.reduce(0, +)) / Double(total) * 100)
        if pct / 10 != lastPercent / 10 {
            lastPercent = pct
            log("progress \(pct)%")
        }
    }
}

func discover(_ args: Args) async {
    let identity = loadIdentity(args)
    let port = args.int("--port") ?? SlipConstants.defaultPort
    let transport: TransportProtocol = args.has("--http") ? .http : .https
    let timeout = Double(args.value("--timeout") ?? "5") ?? 5
    let info = makeInfo(identity, args: args, port: port, transport: transport)
    let seen = PeerSet()

    // Run a server so peers can answer our announcement via POST /register.
    let server = SlipServer(identity: identity, deviceInfo: info,
                            configuration: ReceiverConfiguration(port: port, transport: transport,
                                                                 saveDirectory: FileManager.default.temporaryDirectory),
                            decide: { _ in .decline }, events: { event in
                                if case .peerRegistered(let p, let ip) = event { seen.add(DiscoveredPeer(info: p, ip: ip), .register) }
                            })
    do { try await server.start() } catch { log("note: could not listen on \(port) (\(error.localizedDescription)); relying on multicast replies") }

    let discovery = DiscoveryService(client: SlipClient(), info: { info }) { peer, source in seen.add(peer, source) }
    do {
        try await discovery.start()
        discovery.announce()
    } catch {
        log("multicast unavailable: \(error)")
    }
    if args.has("--scan") {
        let ports = args.options["--scan-port"]?.compactMap(Int.init) ?? [SlipConstants.defaultPort]
        Task { await discovery.scan(ports: ports) }
    }
    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
    discovery.stop()
    await server.stop()
    let peers = seen.all
    log("\(peers.count) peer(s) found")
    exit(0)
}

final class PeerSet: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String: DiscoveredPeer] = [:]

    func add(_ p: DiscoveredPeer, _ source: DiscoverySource) {
        lock.lock(); defer { lock.unlock() }
        let isNew = peers[p.id] == nil
        if isNew || peers[p.id] != p { peers[p.id] = p }
        if isNew {
            log("\(p.info.alias)\t\(p.address)\t\(p.info.deviceModel ?? "-")/\(p.info.deviceType?.rawValue ?? "-")\tvia \(source.rawValue)\tfp=\(p.info.fingerprint.prefix(16))…")
        }
    }

    var all: [DiscoveredPeer] { lock.lock(); defer { lock.unlock() }; return Array(peers.values) }
}

func info(_ args: Args) async {
    do {
        let i = try await SlipClient().info(at: peerAddress(args))
        log(String(data: try SlipJSON.encode(i), encoding: .utf8)!)
        exit(0)
    } catch { fail("\(error.localizedDescription)") }
}

func register(_ args: Args) async {
    let identity = loadIdentity(args)
    let target = peerAddress(args)
    let me = makeInfo(identity, args: args, port: args.int("--port") ?? SlipConstants.defaultPort, transport: target.transport)
    do {
        let i = try await SlipClient().register(at: target, info: me)
        log(String(data: try SlipJSON.encode(i), encoding: .utf8)!)
        exit(0)
    } catch { fail("\(error.localizedDescription)") }
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
switch args.command {
case "receive": await receive(args)
case "send": await send(args)
case "discover": await discover(args)
case "info": await info(args)
case "register": await register(args)
default:
    print(usage)
    exit(args.command == "help" || args.command == "--help" ? 0 : 1)
}
