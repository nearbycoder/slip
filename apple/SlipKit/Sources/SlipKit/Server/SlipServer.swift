import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public enum SlipServerError: Error, LocalizedError {
    case notRunning
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Server is not running"
        case .bindFailed(let s): return "Could not start server: \(s)"
        }
    }
}

/// The LocalSend v2 HTTP(S) receiver.
public final class SlipServer: @unchecked Sendable {
    public typealias DecisionHandler = @Sendable (IncomingRequest) async -> ReceiveDecision
    public typealias EventHandler = @Sendable (ReceiverEvent) -> Void

    public let identity: SlipIdentity
    let store = ReceiveStore()
    private let lock = NIOLock()
    private var _configuration: ReceiverConfiguration
    private var _deviceInfo: DeviceInfo
    private var channel: Channel?
    private let group: EventLoopGroup
    private let decide: DecisionHandler
    private let events: EventHandler

    public init(identity: SlipIdentity, deviceInfo: DeviceInfo, configuration: ReceiverConfiguration,
                group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                decide: @escaping DecisionHandler, events: @escaping EventHandler) {
        self.identity = identity
        self._deviceInfo = deviceInfo
        self._configuration = configuration
        self.group = group
        self.decide = decide
        self.events = events
    }

    /// Live-updatable settings (PIN, auto-accept, save dir). Port/transport need a restart.
    public var configuration: ReceiverConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    /// The `DeviceInfo` we advertise. `port`/`protocol`/`fingerprint` are filled from the
    /// configuration when serving.
    public var deviceInfo: DeviceInfo {
        get {
            lock.withLock {
                var info = _deviceInfo
                info.port = boundPortUnlocked ?? _configuration.port
                info.protocol = _configuration.transport
                info.fingerprint = identity.fingerprint(for: _configuration.transport)
                return info
            }
        }
        set { lock.withLock { _deviceInfo = newValue } }
    }

    private var boundPortUnlocked: Int? { channel?.localAddress?.port }
    public var boundPort: Int? { lock.withLock { boundPortUnlocked } }
    public var isRunning: Bool { lock.withLock { channel != nil } }

    /// Starts listening. Returns the bound port (useful with port 0).
    @discardableResult
    public func start() async throws -> Int {
        let config = configuration
        let sslContext: NIOSSLContext? = config.transport == .https ? try makeSSLContext() : nil
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelInitializer { [weak self] ch in
                guard let self else { return ch.eventLoop.makeSucceededVoidFuture() }
                do {
                    if let sslContext {
                        try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    }
                    try ch.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    try ch.pipeline.syncOperations.addHandler(SlipHTTPHandler(server: self))
                    return ch.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
        let ch: Channel
        do {
            ch = try await bootstrap.bind(host: config.bindHost, port: config.port).get()
        } catch {
            throw SlipServerError.bindFailed("\(error)")
        }
        lock.withLock { channel = ch }
        return ch.localAddress?.port ?? config.port
    }

    public func stop() async {
        let ch: Channel? = lock.withLock { defer { channel = nil }; return channel }
        try? await ch?.close().get()
    }

    /// Receiver-side cancel of an active session.
    public func cancelSession(_ sessionId: String) {
        guard let s = store.cancelActive(sessionId: sessionId) else { return }
        s.activeChannels.values.forEach { $0.close(promise: nil) }
        events(.sessionFinished(sessionId: sessionId, cancelled: true))
    }

    func makeSSLContext() throws -> NIOSSLContext {
        let cert = try NIOSSLCertificate(bytes: [UInt8](identity.certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: [UInt8](identity.privateKeyPEM.utf8), format: .pem)
        let tls = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        return try NIOSSLContext(configuration: tls)
    }

    func emit(_ event: ReceiverEvent) { events(event) }

    // MARK: - Route logic (transport-independent)

    struct Reply {
        var status: HTTPResponseStatus
        var body: Data?
        static func json<T: Encodable>(_ value: T) -> Reply {
            Reply(status: .ok, body: try? SlipJSON.encode(value))
        }
        static func message(_ status: HTTPResponseStatus, _ text: String) -> Reply {
            Reply(status: status, body: try? SlipJSON.encode(["message": text]))
        }
    }

    func handleRegister(body: Data, ip: String) -> Reply {
        if let peer = try? SlipJSON.decode(DeviceInfo.self, from: body),
           peer.fingerprint != deviceInfo.fingerprint {
            emit(.peerRegistered(peer, ip: ip))
        }
        return .json(deviceInfo)
    }

    func handlePrepareUpload(body: Data, pin: String?, ip: String, onPending: (PendingDecision) -> Void) async -> Reply {
        let config = configuration
        if let required = config.pin, !required.isEmpty, pin != required {
            return .message(.unauthorized, pin == nil ? "PIN required" : "Invalid PIN")
        }
        guard let request = try? SlipJSON.decode(PrepareUploadRequest.self, from: body), !request.files.isEmpty else {
            return .message(.badRequest, "Request body malformed")
        }
        if request.isTextMessage {
            let text = request.files.values.sorted { $0.id < $1.id }.compactMap(\.preview).joined(separator: "\n")
            emit(.textMessage(text, from: request.info, ip: ip))
            return Reply(status: .noContent, body: nil)
        }
        let files = request.files.values.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        let incoming = IncomingRequest(id: UUID(), sender: request.info, senderIP: ip, files: files)
        guard let pending = store.beginPending(incoming, staleAfter: config.staleSessionTimeout) else {
            return .message(.conflict, "Blocked by another session")
        }
        onPending(pending)

        let decision: ReceiveDecision
        if config.autoAccept {
            decision = .accept(nil)
            pending.resolve(.decided(decision))
        } else {
            let decideTask = Task { [decide] in
                let d = await decide(incoming)
                pending.resolve(.decided(d))
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(config.decisionTimeout * 1_000_000_000))
                if pending.resolve(.timedOut) { decideTask.cancel() }
            }
            let outcome = await pending.wait()
            timeoutTask.cancel()
            switch outcome {
            case .decided(let d):
                decision = d
            case .timedOut:
                store.clearPending(pending)
                emit(.requestWithdrawn(incoming.id))
                return .message(.forbidden, "Request timed out")
            case .withdrawn:
                decideTask.cancel()
                store.clearPending(pending)
                emit(.requestWithdrawn(incoming.id))
                return .message(.forbidden, "Cancelled")
            }
        }

        guard case .accept(let selected) = decision else {
            store.clearPending(pending)
            return .message(.forbidden, "Rejected")
        }
        let accepted = files.filter { selected?.contains($0.id) ?? true }
        guard !accepted.isEmpty else {
            store.clearPending(pending)
            return .message(.forbidden, "Rejected")
        }
        let sessionId = UUID().uuidString
        let tokens = Dictionary(uniqueKeysWithValues: accepted.map { ($0.id, SlipIdentity.randomHex(byteCount: 16)) })
        let info = ReceiveSessionInfo(sessionId: sessionId, requestId: incoming.id, sender: request.info,
                                      senderIP: ip, files: accepted, saveDirectory: config.saveDirectory)
        guard store.activate(pending, session: ReceiveSession(info: info, tokens: tokens)) else {
            emit(.requestWithdrawn(incoming.id))
            return .message(.forbidden, "Cancelled")
        }
        emit(.sessionStarted(info))
        return .json(PrepareUploadResponse(sessionId: sessionId, files: tokens))
    }

    func handleCancel(sessionId: String?, ip: String) -> Reply {
        switch store.cancel(sessionId: sessionId, ip: ip) {
        case .none:
            break
        case .pending(let p):
            p.resolve(.withdrawn)
        case .session(let s):
            s.activeChannels.values.forEach { $0.close(promise: nil) }
            emit(.sessionFinished(sessionId: s.info.sessionId, cancelled: true))
        }
        return Reply(status: .ok, body: nil)
    }
}

// MARK: - Upload writer

/// Streams one upload to `<dir>/.slip-partial-<uuid>` on a private serial queue.
final class UploadWriter: @unchecked Sendable {
    let ticket: UploadTicket
    let partialURL: URL
    let finalParent: URL
    let finalName: String
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "slip.upload")
    private var hasher: SHA256?
    private(set) var writeError: Error?
    private var closed = false
    /// Bytes received (event-loop side).
    var received: Int64 = 0
    var lastReported: Int64 = 0
    /// Writes queued but not yet completed (event-loop side).
    var inFlight = 0

    init(ticket: UploadTicket) throws {
        self.ticket = ticket
        let segs = PathSanitizer.segments(of: ticket.file.fileName)
        var parent = ticket.saveDirectory
        for dir in segs.dropLast() { parent.appendPathComponent(dir, isDirectory: true) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        finalParent = parent
        finalName = segs.last!
        partialURL = parent.appendingPathComponent(".slip-partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: partialURL.path])
        }
        handle = try FileHandle(forWritingTo: partialURL)
        if let sha = ticket.file.sha256, !sha.isEmpty { hasher = SHA256() }
    }

    func write(_ data: Data, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if writeError == nil && !closed {
                do {
                    try handle.write(contentsOf: data)
                    hasher?.update(data: data)
                } catch {
                    writeError = error
                }
            }
            completion()
        }
    }

    /// Closes the file and returns the lowercase hex digest if one was computed.
    func finish(completion: @escaping @Sendable (_ digest: String?, _ error: Error?) -> Void) {
        queue.async { [self] in
            closed = true
            try? handle.synchronize()
            try? handle.close()
            let digest = hasher.map { $0.finalize().map { String(format: "%02x", $0) }.joined() }
            completion(digest, writeError)
        }
    }

    func abort() {
        queue.async { [self] in
            if !closed {
                closed = true
                try? handle.close()
            }
            try? FileManager.default.removeItem(at: partialURL)
        }
    }

    func discardPartial() { try? FileManager.default.removeItem(at: partialURL) }
}

// MARK: - Channel handler

final class SlipHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case buffering(HTTPRequestHead, ByteBuffer)
        case uploading(HTTPRequestHead, UploadWriter)
        case discarding(HTTPRequestHead, SlipServer.Reply)
        case responding
    }

    private static let maxJSONBody = 32 * 1024 * 1024
    private let server: SlipServer
    private var state: State = .idle
    private var pending: PendingDecision?
    private var autoReadDisabled = false

    init(server: SlipServer) { self.server = server }

    private func remoteIP(_ context: ChannelHandlerContext) -> String {
        var ip = context.channel.remoteAddress?.ipAddress ?? ""
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        return ip
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            onHead(context: context, head: head)
        case .body(let buffer):
            onBody(context: context, buffer: buffer)
        case .end:
            onEnd(context: context)
        }
    }

    private func onHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let (path, query) = Self.split(uri: head.uri)
        if head.method == .POST && path == SlipConstants.apiPrefix + "/upload" {
            guard let sessionId = query["sessionId"], let fileId = query["fileId"], let token = query["token"] else {
                state = .discarding(head, .message(.badRequest, "Missing parameters"))
                return
            }
            switch server.store.beginUpload(sessionId: sessionId, fileId: fileId, token: token,
                                            ip: remoteIP(context), channel: context.channel) {
            case .forbidden:
                state = .discarding(head, .message(.forbidden, "Invalid token or IP address"))
            case .conflict:
                state = .discarding(head, .message(.conflict, "Blocked by another session"))
            case .ok(let ticket):
                do {
                    state = .uploading(head, try UploadWriter(ticket: ticket))
                } catch {
                    _ = server.store.finishUpload(ticket, success: false, channel: context.channel)
                    server.emit(.fileFailed(sessionId: ticket.sessionId, fileId: ticket.file.id, reason: error.localizedDescription))
                    state = .discarding(head, .message(.internalServerError, "Could not create file"))
                }
            }
        } else {
            state = .buffering(head, context.channel.allocator.buffer(capacity: 0))
        }
    }

    private func onBody(context: ChannelHandlerContext, buffer: ByteBuffer) {
        switch state {
        case .buffering(let head, var acc):
            if acc.readableBytes + buffer.readableBytes > Self.maxJSONBody {
                state = .discarding(head, .message(.payloadTooLarge, "Body too large"))
                return
            }
            var b = buffer
            acc.writeBuffer(&b)
            state = .buffering(head, acc)
        case .uploading(_, let writer):
            let data = Data(buffer.readableBytesView)
            writer.received += Int64(data.count)
            writer.inFlight += 1
            if writer.inFlight > 8 && !autoReadDisabled {
                autoReadDisabled = true
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            }
            let loop = context.eventLoop
            let channel = context.channel
            writer.write(data) { [weak self] in
                loop.execute {
                    writer.inFlight -= 1
                    if let self, self.autoReadDisabled, writer.inFlight <= 2 {
                        self.autoReadDisabled = false
                        _ = channel.setOption(ChannelOptions.autoRead, value: true)
                    }
                }
            }
            if writer.received - writer.lastReported >= 256 * 1024 {
                writer.lastReported = writer.received
                server.store.touch(sessionId: writer.ticket.sessionId)
                server.emit(.fileProgress(sessionId: writer.ticket.sessionId, fileId: writer.ticket.file.id,
                                          received: writer.received, total: writer.ticket.file.size))
            }
        default:
            break
        }
    }

    private func onEnd(context: ChannelHandlerContext) {
        let ip = remoteIP(context)
        switch state {
        case .discarding(let head, let reply):
            state = .responding
            respond(context: context, head: head, reply: reply)
        case .buffering(let head, let buffer):
            state = .responding
            route(context: context, head: head, body: Data(buffer.readableBytesView), ip: ip)
        case .uploading(let head, let writer):
            state = .responding
            finishUpload(context: context, head: head, writer: writer)
        default:
            break
        }
    }

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data, ip: String) {
        let (path, query) = Self.split(uri: head.uri)
        let prefix = SlipConstants.apiPrefix
        switch (head.method, path) {
        case (.GET, prefix + "/info"), (.POST, prefix + "/info"):
            respond(context: context, head: head, reply: .json(server.deviceInfo))
        case (.POST, prefix + "/register"):
            respond(context: context, head: head, reply: server.handleRegister(body: body, ip: ip))
        case (.POST, prefix + "/prepare-upload"):
            let loop = context.eventLoop
            let promise = loop.makePromise(of: SlipServer.Reply.self)
            let server = self.server
            let pin = query["pin"]
            promise.completeWithTask {
                await server.handlePrepareUpload(body: body, pin: pin, ip: ip) { [weak self] p in
                    loop.execute { self?.pending = p }
                }
            }
            promise.futureResult.whenSuccess { [weak self] reply in
                self?.pending = nil
                self?.respond(context: context, head: head, reply: reply)
            }
        case (.POST, prefix + "/cancel"):
            respond(context: context, head: head, reply: server.handleCancel(sessionId: query["sessionId"], ip: ip))
        default:
            respond(context: context, head: head, reply: .message(.notFound, "Not found"))
        }
    }

    private func finishUpload(context: ChannelHandlerContext, head: HTTPRequestHead, writer: UploadWriter) {
        let loop = context.eventLoop
        let channel = context.channel
        let server = self.server
        let ticket = writer.ticket
        writer.finish { [weak self] digest, error in
            var reply = SlipServer.Reply(status: .ok, body: nil)
            var finalURL: URL?
            var failure: String?
            if let error {
                writer.discardPartial()
                failure = error.localizedDescription
                reply = .message(.internalServerError, "Write failed")
            } else if let expected = ticket.file.sha256, !expected.isEmpty, digest != expected.lowercased() {
                writer.discardPartial()
                failure = "Checksum mismatch"
                reply = .message(.unprocessableEntity, "Checksum mismatch (sha256)")
            } else if !server.store.isSessionActive(ticket.sessionId) {
                writer.discardPartial()
                failure = "Cancelled"
                reply = .message(.forbidden, "Session cancelled")
            } else {
                do {
                    let dest: URL = try server.store.withFinalizeLock {
                        let dest = PathSanitizer.uniqueFile(named: writer.finalName, in: writer.finalParent)
                        try FileManager.default.moveItem(at: writer.partialURL, to: dest)
                        return dest
                    }
                    if let modified = ticket.file.metadata?.modified {
                        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dest.path)
                    }
                    finalURL = dest
                } catch {
                    writer.discardPartial()
                    failure = error.localizedDescription
                    reply = .message(.internalServerError, "Could not save file")
                }
            }
            loop.execute {
                if let finalURL {
                    server.emit(.fileProgress(sessionId: ticket.sessionId, fileId: ticket.file.id,
                                              received: writer.received, total: writer.received))
                    server.emit(.fileFinished(sessionId: ticket.sessionId, fileId: ticket.file.id, url: finalURL))
                } else if let failure {
                    server.emit(.fileFailed(sessionId: ticket.sessionId, fileId: ticket.file.id, reason: failure))
                }
                let result = server.store.finishUpload(ticket, success: finalURL != nil, channel: channel)
                if result.sessionEnded {
                    server.emit(.sessionFinished(sessionId: ticket.sessionId, cancelled: false))
                }
                self?.respond(context: context, head: head, reply: reply)
            }
        }
    }

    private func respond(context: ChannelHandlerContext, head: HTTPRequestHead, reply: SlipServer.Reply) {
        guard context.channel.isActive else { return }
        var headers = HTTPHeaders()
        let body = reply.body ?? Data()
        if reply.body != nil { headers.add(name: "Content-Type", value: "application/json") }
        headers.add(name: "Content-Length", value: "\(body.count)")
        let keepAlive = head.isKeepAlive
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let responseHead = HTTPResponseHead(version: head.version, status: reply.status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if !body.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
        state = .idle
        if autoReadDisabled {
            autoReadDisabled = false
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if case .uploading(_, let writer) = state {
            writer.abort()
            let ticket = writer.ticket
            if server.store.isSessionActive(ticket.sessionId) {
                server.emit(.fileFailed(sessionId: ticket.sessionId, fileId: ticket.file.id, reason: "Connection lost"))
                if server.store.finishUpload(ticket, success: false, channel: context.channel).sessionEnded {
                    server.emit(.sessionFinished(sessionId: ticket.sessionId, cancelled: false))
                }
            }
        }
        state = .idle
        // Sender gave up while we were waiting for the user.
        pending?.resolve(.withdrawn)
        pending = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    static func split(uri: String) -> (String, [String: String]) {
        guard let comps = URLComponents(string: uri) else { return (uri, [:]) }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return (path, query)
    }
}
