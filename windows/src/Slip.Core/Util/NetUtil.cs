using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Slip.Core.Util;

public sealed record LocalInterface(string Name, int Index, IPAddress Address, int PrefixLength, bool SupportsMulticast);

public static class NetUtil
{
    /// <summary>All up, non-loopback IPv4 interface addresses.</summary>
    public static IReadOnlyList<LocalInterface> GetIPv4Interfaces()
    {
        var result = new List<LocalInterface>();
        NetworkInterface[] nics;
        try { nics = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { return result; }

        foreach (var nic in nics)
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch (NetworkInformationException) { continue; }

            var index = 0;
            try { index = props.GetIPv4Properties()?.Index ?? 0; }
            catch (Exception e) when (e is NetworkInformationException or PlatformNotSupportedException) { }

            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                if (IPAddress.IsLoopback(ua.Address)) continue;
                var bytes = ua.Address.GetAddressBytes();
                if (bytes[0] == 169 && bytes[1] == 254) continue; // link-local / APIPA
                var prefix = ua.PrefixLength is > 0 and <= 32 ? ua.PrefixLength : 24;
                result.Add(new LocalInterface(nic.Name, index, ua.Address, prefix, nic.SupportsMulticast));
            }
        }
        return result;
    }

    /// <summary>Hosts to probe for the HTTP scan fallback: every host in each /24 (or smaller) subnet.</summary>
    public static IEnumerable<IPAddress> ScanTargets(IEnumerable<LocalInterface> interfaces)
    {
        var seen = new HashSet<uint>();
        foreach (var iface in interfaces)
        {
            var prefix = Math.Max(iface.PrefixLength, 24); // never scan more than a /24
            if (prefix >= 31) continue;
            var ip = ToUInt(iface.Address);
            var mask = prefix == 0 ? 0u : uint.MaxValue << (32 - prefix);
            var network = ip & mask;
            var broadcast = network | ~mask;
            for (var host = network + 1; host < broadcast; host++)
            {
                if (host == ip || !seen.Add(host)) continue;
                yield return FromUInt(host);
            }
        }
    }

    public static IPAddress Normalize(IPAddress address) =>
        address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;

    internal static uint ToUInt(IPAddress address)
    {
        var b = address.GetAddressBytes();
        return (uint)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
    }

    internal static IPAddress FromUInt(uint value) =>
        new([(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value]);

    /// <summary>Formats "host:port", bracketing IPv6 literals.</summary>
    public static string HostPort(string host, int port) =>
        host.Contains(':') && !host.StartsWith('[') ? $"[{host}]:{port}" : $"{host}:{port}";
}
