import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A peer seen via multicast, /register or scan.
public struct DiscoveredPeer: Sendable, Hashable, Identifiable {
    public var info: DeviceInfo
    public var ip: String
    public var id: String { info.fingerprint }
    public var address: PeerAddress { PeerAddress(host: ip, port: info.port, transport: info.protocol) }

    public init(info: DeviceInfo, ip: String) {
        self.info = info
        self.ip = ip
    }
}

public enum DiscoverySource: String, Sendable {
    case multicast, register, scan
}

/// UDP multicast listener/sender bound to `0.0.0.0:<port>` with SO_REUSEADDR/SO_REUSEPORT.
public final class MulticastSocket: @unchecked Sendable {
    public let groupAddress: String
    public let port: Int
    private let onPacket: @Sendable (MulticastPacket, String) -> Void
    private let lock = NIOLock()
    private var channel: Channel?
    private var interfaces: [IPv4Interface] = []
    private let elg: EventLoopGroup

    public init(groupAddress: String = SlipConstants.multicastGroup, port: Int = SlipConstants.multicastPort,
                group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                onPacket: @escaping @Sendable (MulticastPacket, String) -> Void) {
        self.groupAddress = groupAddress
        self.port = port
        self.elg = group
        self.onPacket = onPacket
    }

    /// Binds and joins the group on every non-loopback IPv4 interface. Returns the number of
    /// interfaces joined (0 means only the default interface could be used).
    @discardableResult
    public func start() async throws -> Int {
        let handler = MulticastHandler(onPacket: onPacket)
        let bootstrap = DatagramBootstrap(group: elg)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture { try ch.pipeline.syncOperations.addHandler(handler) }
            }
        let ch = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        let group = try SocketAddress(ipAddress: groupAddress, port: port)
        var joined = 0
        let ifaces = NetworkInterfaces.ipv4().filter(\.supportsMulticast)
        if let mc = ch as? MulticastChannel {
            let devices = (try? System.enumerateDevices()) ?? []
            for iface in ifaces {
                guard let dev = devices.first(where: { $0.name == iface.name && $0.address?.ipAddress == iface.address }) else { continue }
                do {
                    try await mc.joinGroup(group, device: dev).get()
                    joined += 1
                } catch {
                    // Not fatal: e.g. iOS without the multicast entitlement.
                }
            }
            if joined == 0 { _ = try? await mc.joinGroup(group).get() }
        }
        _ = try? await ch.setOption(ChannelOptions.ipOption(.ip_multicast_ttl), value: 32).get()
        _ = try? await ch.setOption(ChannelOptions.ipOption(.ip_multicast_loop), value: 1).get()
        lock.withLock {
            channel = ch
            interfaces = ifaces
        }
        return joined
    }

    public func stop() {
        let ch: Channel? = lock.withLock { defer { channel = nil }; return channel }
        ch?.close(promise: nil)
    }

    /// Sends one packet to the group, once per multicast-capable interface.
    public func send(_ packet: MulticastPacket) async {
        let (ch, ifaces): (Channel?, [IPv4Interface]) = lock.withLock { (channel, interfaces) }
        guard let ch, let data = try? SlipJSON.encode(packet),
              let group = try? SocketAddress(ipAddress: groupAddress, port: port) else { return }
        func write() async {
            var buf = ch.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            _ = try? await ch.writeAndFlush(AddressedEnvelope(remoteAddress: group, data: buf)).get()
        }
        if ifaces.isEmpty {
            await write()
            return
        }
        for iface in ifaces {
            let addr = CInt(bitPattern: iface.addressValue.bigEndian)
            if (try? await ch.setOption(ChannelOptions.ipOption(.ip_multicast_if), value: addr).get()) != nil {
                await write()
            }
        }
    }
}

private final class MulticastHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let onPacket: @Sendable (MulticastPacket, String) -> Void

    init(onPacket: @escaping @Sendable (MulticastPacket, String) -> Void) { self.onPacket = onPacket }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let ip = envelope.remoteAddress.ipAddress,
              let packet = try? SlipJSON.decode(MulticastPacket.self, from: Data(envelope.data.readableBytesView)) else { return }
        onPacket(packet, ip)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Ignore transient UDP errors (e.g. EHOSTUNREACH on send).
    }
}

/// Multicast announce/respond + HTTP /24 scan, per IMPLEMENTATION.md "Discovery".
public final class DiscoveryService: @unchecked Sendable {
    public typealias PeerHandler = @Sendable (DiscoveredPeer, DiscoverySource) -> Void

    private let client: SlipClient
    private let infoProvider: @Sendable () -> DeviceInfo
    private let onPeer: PeerHandler
    private let lock = NIOLock()
    private var socket: MulticastSocket?
    private var _discoverable = true
    private var announceTask: Task<Void, Never>?
    public let multicastGroup: String
    public let multicastPort: Int

    public init(client: SlipClient, multicastGroup: String = SlipConstants.multicastGroup,
                multicastPort: Int = SlipConstants.multicastPort,
                info: @escaping @Sendable () -> DeviceInfo, onPeer: @escaping PeerHandler) {
        self.client = client
        self.multicastGroup = multicastGroup
        self.multicastPort = multicastPort
        self.infoProvider = info
        self.onPeer = onPeer
    }

    /// When false we neither announce nor answer announcements (we still listen).
    public var discoverable: Bool {
        get { lock.withLock { _discoverable } }
        set { lock.withLock { _discoverable = newValue } }
    }

    /// Starts the multicast listener. Throws if the UDP socket can't be bound.
    public func start() async throws {
        let socket = MulticastSocket(groupAddress: multicastGroup, port: multicastPort) { [weak self] packet, ip in
            self?.handle(packet, ip: ip)
        }
        try await socket.start()
        lock.withLock { self.socket = socket }
    }

    public func stop() {
        let s: MulticastSocket? = lock.withLock { defer { socket = nil }; return socket }
        s?.stop()
        announceTask?.cancel()
    }

    /// Sends our announcement three times (~100 ms, ~500 ms, ~2 s).
    public func announce() {
        guard discoverable else { return }
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            var elapsed: UInt64 = 0
            for at: UInt64 in [100, 500, 2000] {
                try? await Task.sleep(nanoseconds: (at - elapsed) * 1_000_000)
                elapsed = at
                guard let self, !Task.isCancelled else { return }
                await self.sendPacket(announce: true)
            }
        }
    }

    private func sendPacket(announce: Bool) async {
        let s: MulticastSocket? = lock.withLock { socket }
        await s?.send(MulticastPacket(info: infoProvider(), announce: announce))
    }

    private func handle(_ packet: MulticastPacket, ip: String) {
        let me = infoProvider()
        guard packet.info.fingerprint != me.fingerprint, !packet.info.fingerprint.isEmpty else { return }
        let peer = DiscoveredPeer(info: packet.info, ip: ip)
        onPeer(peer, .multicast)
        guard packet.announce, discoverable else { return }
        Task { [client, weak self] in
            do {
                let info = try await client.register(at: peer.address, info: me, timeout: 3)
                // Keep the announced address; refresh alias/model from the response.
                var updated = peer
                updated.info.alias = info.alias
                if let model = info.deviceModel { updated.info.deviceModel = model }
                self?.onPeer(updated, .register)
            } catch {
                await self?.sendPacket(announce: false)
            }
        }
    }

    /// HTTP fallback: POST /register to every host of each local /24 (≤ 50 concurrent, ~1 s
    /// timeout each). Returns the peers that answered.
    @discardableResult
    public func scan(ports: [Int]? = nil, transport: TransportProtocol? = nil, timeout: TimeInterval = 1,
                     concurrency: Int = 50) async -> [DiscoveredPeer] {
        let me = infoProvider()
        let ports = ports ?? [me.port]
        let transport = transport ?? me.protocol
        let interfaces = NetworkInterfaces.ipv4()
        var hosts: [String] = []
        var seen = Set(interfaces.map(\.address))
        for iface in interfaces where !iface.name.hasPrefix("utun") {
            for h in iface.scanHosts() where !seen.contains(h) {
                seen.insert(h)
                hosts.append(h)
            }
        }
        let targets = hosts.flatMap { h in ports.map { PeerAddress(host: h, port: $0, transport: transport) } }
        let client = self.client
        let onPeer = self.onPeer
        return await withTaskGroup(of: DiscoveredPeer?.self) { group in
            var it = targets.makeIterator()
            var found: [DiscoveredPeer] = []
            func addNext() -> Bool {
                guard let target = it.next() else { return false }
                group.addTask {
                    guard let info = try? await client.register(at: target, info: me, timeout: timeout),
                          info.fingerprint != me.fingerprint else { return nil }
                    var peerInfo = info
                    peerInfo.port = target.port
                    peerInfo.protocol = target.transport
                    let peer = DiscoveredPeer(info: peerInfo, ip: target.host)
                    onPeer(peer, .scan)
                    return peer
                }
                return true
            }
            for _ in 0..<concurrency { if !addNext() { break } }
            while let r = await group.next() {
                if let r { found.append(r) }
                if Task.isCancelled { group.cancelAll(); break }
                _ = addNext()
            }
            return found
        }
    }
}
