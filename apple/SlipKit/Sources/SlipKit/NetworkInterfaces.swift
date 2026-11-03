import Foundation

/// A local IPv4 interface address.
public struct IPv4Interface: Sendable, Hashable {
    public var name: String
    public var address: String
    public var netmask: String
    /// Host-order address and mask, for subnet arithmetic.
    public var addressValue: UInt32
    public var netmaskValue: UInt32
    public var supportsMulticast: Bool

    public var prefixLength: Int { netmaskValue.nonzeroBitCount }

    /// All host addresses in this interface's subnet (excluding network, broadcast and
    /// ourselves). Only for /24 or smaller subnets; larger ones are clamped to the /24
    /// containing our address.
    public func scanHosts() -> [String] {
        let mask: UInt32 = prefixLength >= 24 ? netmaskValue : 0xFFFF_FF00
        let network = addressValue & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).compactMap { $0 == addressValue ? nil : IPv4Interface.format($0) }
    }

    static func format(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}

public enum NetworkInterfaces {
    /// Non-loopback, up IPv4 interfaces.
    public static func ipv4(includeLoopback: Bool = false) -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0 else { continue }
            let isLoopback = flags & IFF_LOOPBACK != 0
            if isLoopback && !includeLoopback { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var m: UInt32 = 0xFFFF_FF00
            if let mask = ifa.pointee.ifa_netmask {
                m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            let name = String(cString: ifa.pointee.ifa_name)
            // Skip link-local 169.254/16 and point-to-point tunnels (VPN utun) for scanning.
            if (a >> 16) == 0xA9FE { continue }
            result.append(IPv4Interface(name: name, address: IPv4Interface.format(a), netmask: IPv4Interface.format(m),
                                        addressValue: a, netmaskValue: m,
                                        supportsMulticast: flags & IFF_MULTICAST != 0 && flags & IFF_POINTOPOINT == 0))
        }
        return result
    }

    /// Our IPv4 addresses for display.
    public static func displayAddresses() -> [String] {
        let all = ipv4()
        let preferred = all.filter { $0.name.hasPrefix("en") }
        return (preferred.isEmpty ? all : preferred).map(\.address)
    }
}
