import Foundation
import Network
import Observation

/// The app-facing model: owns the server, discovery and sending, and exposes observable
/// state for SwiftUI. All mutation happens on the main actor.
@MainActor
@Observable
public final class SlipController {
    // MARK: Observable state

    public var settings: SlipSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            applySettingsChange(from: oldValue)
        }
    }

    public private(set) var isRunning = false
    public private(set) var serverError: String?
    public private(set) var discoveryError: String?
    public private(set) var peers: [DiscoveredPeer] = []
    public private(set) var isScanning = false
    public private(set) var localAddresses: [String] = []
    /// The incoming request waiting for Accept/Decline.
    public private(set) var pendingRequest: IncomingRequest?
    public private(set) var transfers: [Transfer] = []
    public private(set) var messages: [ReceivedMessage] = []
    /// Set when the latest message should be presented.
    public var presentedMessage: ReceivedMessage?
    public var pinPrompt: PinPrompt?
    public private(set) var identity: SlipIdentity

    // MARK: Hooks for platform UI (notifications, sounds…)

    @ObservationIgnored public var onIncomingRequest: ((IncomingRequest) -> Void)?
    @ObservationIgnored public var onTransferFinished: ((Transfer) -> Void)?
    @ObservationIgnored public var onMessage: ((ReceivedMessage) -> Void)?

    // MARK: Internals

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client = SlipClient()
    @ObservationIgnored private var server: SlipServer?
    @ObservationIgnored private var discovery: DiscoveryService?
    @ObservationIgnored private var decisionContinuation: CheckedContinuation<ReceiveDecision, Never>?
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var eventContinuation: AsyncStream<ReceiverEvent>.Continuation?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var scopedDirectory: URL?
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, identityURL: URL = SlipIdentity.defaultURL()) {
        self.defaults = defaults
        self.settings = SlipSettings.load(from: defaults)
        if let id = try? SlipIdentity.loadOrCreate(at: identityURL) {
            identity = id
        } else {
            // Fall back to an ephemeral identity rather than failing to launch.
            identity = (try? SlipIdentity.generate())!
        }
    }

    // MARK: Derived

    public var deviceInfo: DeviceInfo {
        DeviceInfo(alias: settings.alias, deviceModel: DeviceDefaults.deviceModel, deviceType: DeviceDefaults.deviceType,
                   fingerprint: identity.fingerprint(for: settings.transport), port: server?.boundPort ?? settings.port,
                   protocol: settings.transport, download: false)
    }

    public var saveDirectory: URL {
        if let scopedDirectory { return scopedDirectory }
        if let p = settings.saveDirectoryPath { return URL(fileURLWithPath: p, isDirectory: true) }
        return SlipSettings.defaultSaveDirectory
    }

    public var activeTransfers: [Transfer] { transfers.filter { !$0.status.isFinished } }

    // MARK: Lifecycle

    public func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        resolveSaveDirectoryBookmark()
        localAddresses = NetworkInterfaces.displayAddresses()
        let (stream, continuation) = AsyncStream<ReceiverEvent>.makeStream()
        eventContinuation = continuation
        Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }

        let server = SlipServer(identity: identity, deviceInfo: deviceInfo, configuration: receiverConfiguration(),
                                decide: { [weak self] request in
                                    await self?.awaitDecision(request) ?? .decline
                                },
                                events: { event in continuation.yield(event) })
        do {
            try await server.start()
            self.server = server
            serverError = nil
        } catch {
            serverError = error.localizedDescription
        }

        let info = deviceInfo
        let infoBox = InfoBox(info)
        let discovery = DiscoveryService(client: client, info: { infoBox.value }) { [weak self] peer, _ in
            Task { @MainActor in self?.upsert(peer) }
        }
        discovery.discoverable = settings.discoverable
        do {
            try await discovery.start()
            discoveryError = nil
        } catch {
            discoveryError = "Multicast unavailable: \(error.localizedDescription)"
        }
        self.discovery = discovery
        self.infoBox = infoBox
        infoBox.value = info
        isRunning = true
        discovery.announce()
        startMaintenance()
        startPathMonitor()
    }

    @ObservationIgnored private var infoBox: InfoBox?
    @ObservationIgnored private var isStarting = false

    public func stop() async {
        resolveDecision(.decline)
        maintenanceTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        discovery?.stop()
        discovery = nil
        await server?.stop()
        server = nil
        eventContinuation?.finish()
        isRunning = false
        if let d = scopedDirectory {
            d.stopAccessingSecurityScopedResource()
            scopedDirectory = nil
        }
    }

    public func restart() async {
        await stop()
        await start()
    }

    /// Re-announce and run the HTTP scan fallback.
    public func refresh() {
        discovery?.announce()
        Task { await scan() }
    }

    public func scan() async {
        guard let discovery, !isScanning else { return }
        isScanning = true
        await discovery.scan()
        isScanning = false
    }

    private func receiverConfiguration() -> ReceiverConfiguration {
        ReceiverConfiguration(port: settings.port, transport: settings.transport, saveDirectory: saveDirectory,
                              pin: settings.effectivePin, autoAccept: settings.quickSave)
    }

    private func applySettingsChange(from old: SlipSettings) {
        if settings.port != old.port || settings.useHTTPS != old.useHTTPS {
            scheduleRestart()
            return
        }
        if settings.saveDirectoryBookmark != old.saveDirectoryBookmark {
            scopedDirectory?.stopAccessingSecurityScopedResource()
            scopedDirectory = nil
            resolveSaveDirectoryBookmark()
        }
        server?.configuration = receiverConfiguration()
        server?.deviceInfo = deviceInfo
        infoBox?.value = deviceInfo
        discovery?.discoverable = settings.discoverable
        if settings.alias != old.alias || (settings.discoverable && !old.discoverable) {
            discovery?.announce()
        }
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.restart()
        }
    }

    private func resolveSaveDirectoryBookmark() {
        #if os(macOS)
        guard scopedDirectory == nil, let bookmark = settings.saveDirectoryBookmark else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
            scopedDirectory = url
        }
        #endif
    }

    /// Sets the save directory from a user-picked folder (stores a security-scoped bookmark on macOS).
    public func setSaveDirectory(_ url: URL?) {
        guard let url else {
            settings.saveDirectoryPath = nil
            settings.saveDirectoryBookmark = nil
            return
        }
        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark: Data? = nil
        #endif
        settings.saveDirectoryPath = url.path
        settings.saveDirectoryBookmark = bookmark
    }

    private func startMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            // Fallback scan if multicast found nobody after a few seconds.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let self, self.peers.isEmpty { await self.scan() }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.expirePeers()
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        var first = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if first { first = false; return }
                self.localAddresses = NetworkInterfaces.displayAddresses()
                // Rejoin multicast on the new interfaces and re-announce.
                if self.activeTransfers.isEmpty && self.pendingRequest == nil { self.scheduleRestart() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: Peers

    private func upsert(_ peer: DiscoveredPeer) {
        guard peer.info.fingerprint != deviceInfo.fingerprint else { return }
        lastSeen[peer.id] = Date()
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            if peers[i] != peer { peers[i] = peer }
        } else {
            peers.append(peer)
            peers.sort { $0.info.alias.localizedCaseInsensitiveCompare($1.info.alias) == .orderedAscending }
        }
    }

    private func expirePeers() {
        let busy = Set(activeTransfers.map(\.peerAlias))
        let cutoff = Date().addingTimeInterval(-60)
        peers.removeAll { p in (lastSeen[p.id] ?? .distantPast) < cutoff && !busy.contains(p.info.alias) }
    }

    /// Adds a device by IP (manual "send to IP"): asks it to register.
    public func addPeer(host: String, port: Int?, transport: TransportProtocol?) async throws -> DiscoveredPeer {
        let address = PeerAddress(host: host, port: port ?? settings.port, transport: transport ?? settings.transport)
        do {
            let info = try await client.register(at: address, info: deviceInfo, timeout: 5)
            let peer = DiscoveredPeer(info: info, ip: host)
            upsert(peer)
            return peer
        } catch where transport == nil {
            // Try the other protocol before giving up.
            let other = PeerAddress(host: host, port: address.port, transport: address.transport == .https ? .http : .https)
            let info = try await client.register(at: other, info: deviceInfo, timeout: 5)
            let peer = DiscoveredPeer(info: info, ip: host)
            upsert(peer)
            return peer
        }
    }

    // MARK: Receiving

    private func awaitDecision(_ request: IncomingRequest) async -> ReceiveDecision {
        decisionContinuation?.resume(returning: .decline)
        return await withCheckedContinuation { cont in
            decisionContinuation = cont
            pendingRequest = request
            onIncomingRequest?(request)
        }
    }

    /// Accept the pending request (optionally only some file ids).
    public func accept(fileIds: Set<String>? = nil) {
        resolveDecision(.accept(fileIds))
    }

    public func decline() {
        resolveDecision(.decline)
    }

    private func resolveDecision(_ d: ReceiveDecision) {
        pendingRequest = nil
        let c = decisionContinuation
        decisionContinuation = nil
        c?.resume(returning: d)
    }

    private func handle(_ event: ReceiverEvent) {
        switch event {
        case .peerRegistered(let info, let ip):
            upsert(DiscoveredPeer(info: info, ip: ip))
        case .textMessage(let text, let from, _):
            let m = ReceivedMessage(text: text, senderAlias: from.alias)
            messages.insert(m, at: 0)
            presentedMessage = m
            onMessage?(m)
        case .requestWithdrawn(let id):
            if pendingRequest?.id == id { resolveDecision(.decline) }
        case .sessionStarted(let info):
            if pendingRequest?.id == info.requestId { pendingRequest = nil }
            let files = info.files.map { TransferFile(id: $0.id, name: $0.fileName, size: $0.size) }
            let t = Transfer(direction: .incoming, peer: info.sender, files: files, status: .inProgress)
            t.sessionId = info.sessionId
            t.saveDirectory = info.saveDirectory
            transfers.insert(t, at: 0)
        case .fileProgress(let sid, let fid, let received, _):
            if let f = incoming(sid)?.file(fid) {
                f.transferred = received
                f.status = .inProgress
            }
        case .fileFinished(let sid, let fid, let url):
            if let f = incoming(sid)?.file(fid) {
                f.transferred = f.size
                f.status = .completed
                f.url = url
            }
        case .fileFailed(let sid, let fid, let reason):
            incoming(sid)?.file(fid)?.status = .failed(reason)
        case .sessionFinished(let sid, let cancelled):
            guard let t = incoming(sid) else { return }
            let anyFailed = t.files.contains { if case .failed = $0.status { return true } else { return false } }
            t.finish(cancelled ? .cancelled : (anyFailed ? .failed("Some files failed") : .completed))
            onTransferFinished?(t)
        }
    }

    private func incoming(_ sessionId: String) -> Transfer? {
        transfers.first { $0.direction == .incoming && $0.sessionId == sessionId }
    }

    // MARK: Sending

    /// Sends files/text to a peer. Returns the transfer (observe it for progress).
    @discardableResult
    public func send(_ items: [SendItem], to peer: DiscoveredPeer, pin: String? = nil) -> Transfer {
        let files = items.map { item -> TransferFile in
            var url: URL?
            if case .file(let u) = item.source { url = u }
            return TransferFile(id: item.id, name: item.preview == nil ? item.fileName : "Message", size: item.size, url: url)
        }
        let t = Transfer(direction: .outgoing, peer: peer.info, files: files, status: .waiting)
        t.peerAddress = peer.address
        t.items = items
        transfers.insert(t, at: 0)
        run(t, pin: pin)
        return t
    }

    public func sendText(_ text: String, to peer: DiscoveredPeer) {
        send([.text(text)], to: peer)
    }

    /// Retries a transfer that needed a PIN.
    public func submitPin(_ pin: String, for prompt: PinPrompt) {
        pinPrompt = nil
        guard let t = transfers.first(where: { $0.id == prompt.transferId }) else { return }
        t.status = .waiting
        t.finishedAt = nil
        run(t, pin: pin)
    }

    private func run(_ t: Transfer, pin: String?) {
        guard let address = t.peerAddress else { return }
        let items = t.items
        let info = deviceInfo
        let sender = SlipSender(client: client)
        t.task = Task { [weak self] in
            let outcome = await sender.send(items, to: address, as: info, pin: pin) { event in
                Task { @MainActor in Self.apply(event, to: t) }
            }
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .completed, .delivered: t.finish(.completed)
                case .pinRequired:
                    t.status = .failed("PIN required")
                    self.pinPrompt = PinPrompt(transferId: t.id, peerAlias: t.peerAlias, wasWrong: pin != nil)
                    return
                case .declined: t.finish(.declined)
                case .cancelled: t.finish(.cancelled)
                default: t.finish(.failed(outcome.message))
                }
                self.onTransferFinished?(t)
            }
        }
    }

    private static func apply(_ event: SendEvent, to t: Transfer) {
        switch event {
        case .waitingForAcceptance:
            t.status = .waiting
        case .accepted(let sid, let ids):
            t.sessionId = sid
            t.status = .inProgress
            for f in t.files where !ids.contains(f.id) { f.status = .declined }
        case .fileProgress(let id, let sent, _):
            if let f = t.file(id), !f.status.isFinished {
                f.transferred = max(f.transferred, sent)
                f.status = .inProgress
            }
        case .fileFinished(let id):
            if let f = t.file(id) {
                f.transferred = f.size
                f.status = .completed
            }
        case .fileFailed(let id, let reason):
            t.file(id)?.status = .failed(reason)
        }
    }

    public func cancel(_ t: Transfer) {
        switch t.direction {
        case .outgoing:
            t.task?.cancel()
            if t.status == .waiting { t.finish(.cancelled) }
        case .incoming:
            if let sid = t.sessionId { server?.cancelSession(sid) }
            t.finish(.cancelled)
        }
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.status.isFinished }
    }

    public func dismissPinPrompt() {
        if let p = pinPrompt, let t = transfers.first(where: { $0.id == p.transferId }) {
            t.finish(.failed("PIN required"))
        }
        pinPrompt = nil
    }
}

/// Thread-safe holder for the info the discovery service advertises.
final class InfoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: DeviceInfo
    init(_ v: DeviceInfo) { _value = v }
    var value: DeviceInfo {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
