package app.slip.core.net

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

data class LocalInterface(
    val networkInterface: NetworkInterface,
    val address: Inet4Address,
    val prefixLength: Int,
) {
    val name: String get() = networkInterface.name
}

object NetworkUtil {
    /** Up, non-loopback IPv4 interfaces (virtual/point-to-point ones included; callers may filter). */
    fun ipv4Interfaces(): List<LocalInterface> = runCatching {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .flatMap { ni ->
                ni.interfaceAddresses.orEmpty().mapNotNull { ia ->
                    val addr = ia?.address as? Inet4Address ?: return@mapNotNull null
                    if (addr.isLoopbackAddress || addr.isLinkLocalAddress) null
                    else LocalInterface(ni, addr, ia.networkPrefixLength.toInt())
                }
            }
    }.getOrDefault(emptyList())

    fun multicastInterfaces(): List<NetworkInterface> = ipv4Interfaces()
        .map { it.networkInterface }
        .distinctBy { it.name }
        .filter { runCatching { it.supportsMulticast() }.getOrDefault(false) }

    fun localAddresses(): List<String> = ipv4Interfaces().map { it.address.hostAddress }.distinct()

    /** Host addresses of the /24 (or smaller) subnets of each interface, excluding our own addresses. */
    fun scanTargets(): List<InetAddress> {
        val own = ipv4Interfaces().map { it.address }.toSet()
        return ipv4Interfaces().flatMap { li ->
            val prefix = li.prefixLength.coerceIn(24, 30)
            val ip = li.address.address.fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xff) }
            val mask = (0xffffffffL shl (32 - prefix)) and 0xffffffffL
            val network = ip and mask
            val hosts = (1L shl (32 - prefix)) - 2
            (1..hosts).map { off ->
                val v = network + off
                InetAddress.getByAddress(byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte()))
            }
        }.filter { it !in own }.distinct()
    }
}
