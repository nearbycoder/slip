//! Local network interface helpers.

use std::net::Ipv4Addr;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ipv4Iface {
    pub name: String,
    pub addr: Ipv4Addr,
    pub netmask: Ipv4Addr,
}

impl Ipv4Iface {
    pub fn prefix_len(&self) -> u32 {
        u32::from(self.netmask).count_ones()
    }

    /// Host addresses to scan: the whole subnet if it is /24 or smaller, otherwise the
    /// /24 that contains our address. Excludes network and broadcast. Our own address is
    /// kept so other clients on this host are found (self is filtered by fingerprint).
    pub fn scan_hosts(&self) -> Vec<Ipv4Addr> {
        let prefix = self.prefix_len().max(24);
        let mask: u32 = if prefix >= 32 { u32::MAX } else { !(u32::MAX >> prefix) };
        let ip = u32::from(self.addr);
        let net = ip & mask;
        let bcast = net | !mask;
        if bcast <= net + 1 {
            return vec![];
        }
        ((net + 1)..bcast).map(Ipv4Addr::from).collect()
    }
}

/// Non-loopback, non-link-local IPv4 interfaces.
pub fn ipv4_interfaces() -> Vec<Ipv4Iface> {
    let mut out = Vec::new();
    if let Ok(ifaces) = if_addrs::get_if_addrs() {
        for iface in ifaces {
            if iface.is_loopback() {
                continue;
            }
            if let if_addrs::IfAddr::V4(v4) = &iface.addr {
                if v4.ip.is_link_local() || v4.ip.is_loopback() {
                    continue;
                }
                out.push(Ipv4Iface { name: iface.name.clone(), addr: v4.ip, netmask: v4.netmask });
            }
        }
    }
    out.sort_by_key(|i| i.addr);
    out.dedup_by_key(|i| i.addr);
    out
}

/// Our LAN IPv4 addresses, for display.
pub fn local_ipv4_addrs() -> Vec<Ipv4Addr> {
    ipv4_interfaces().into_iter().map(|i| i.addr).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_hosts_24() {
        let i = Ipv4Iface { name: "x".into(), addr: Ipv4Addr::new(192, 168, 1, 10), netmask: Ipv4Addr::new(255, 255, 255, 0) };
        let h = i.scan_hosts();
        assert_eq!(h.len(), 254);
        assert!(h.contains(&Ipv4Addr::new(192, 168, 1, 10)));
        assert!(h.contains(&Ipv4Addr::new(192, 168, 1, 1)));
        assert!(!h.contains(&Ipv4Addr::new(192, 168, 1, 255)));
    }

    #[test]
    fn scan_hosts_wide_subnet_limited_to_24() {
        let i = Ipv4Iface { name: "x".into(), addr: Ipv4Addr::new(10, 0, 5, 7), netmask: Ipv4Addr::new(255, 0, 0, 0) };
        let h = i.scan_hosts();
        assert_eq!(h.len(), 254);
        assert!(h.iter().all(|a| a.octets()[2] == 5));
    }
}
