import Foundation

/// Link and configuration state, read from the same macOS tools wifidoc.py uses.
enum SystemInfo {
    static func defaultRoute() -> (gateway: String?, iface: String?) {
        let out = run([Bin.route, "-n", "get", "default"])
        return (first(#"gateway:\s*(\S+)"#, out), first(#"interface:\s*(\S+)"#, out))
    }

    static func wifiDevice() -> String {
        first(#"Hardware Port:\s*Wi-Fi\s*\nDevice:\s*(\S+)"#, run([Bin.networksetup, "-listallhardwareports"])) ?? "en0"
    }

    static func ifaceStatus(_ dev: String) -> LinkInfo {
        let out = run([Bin.ifconfig, dev])
        let v4 = findAll(#"\n\s*inet (\d+\.\d+\.\d+\.\d+) netmask (\S+)"#, out)
        let v6 = findAll(#"\n\s*inet6 ([0-9a-f:]+)"#, out, .caseInsensitive).map { $0[0] }
        return LinkInfo(
            active: out.contains("status: active"),
            ipv4: v4.first?[0],
            netmask: v4.first?[1],
            ipv6Global: v6.filter { !$0.lowercased().hasPrefix("fe80") }
        )
    }

    static func dhcpInfo(_ dev: String) -> DHCPInfo {
        let out = run([Bin.ipconfig, "getsummary", dev])
        var info = DHCPInfo()
        info.state = first(#"State\s*:\s*(\S+)"#, out)
        info.router = first(#"Router\s*:\s*(\S+)"#, out)
        if info.router == nil, let m = first(#"router \(ip_mult\): \{([^}]*)\}"#, out) {
            info.router = m.split(separator: ",").first.map { String($0).trimmed }
        }
        if let m = first(#"domain_name_server \(ip_mult\): \{([^}]*)\}"#, out) {
            info.dhcpDNS = m.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        info.leaseExpires = first(#"LeaseExpirationTime\s*:\s*(.+)"#, out)?.trimmed
        let ssid = first(#"\n\s*SSID\s*:\s*(.+)"#, out)?.trimmed
        info.ssid = ssid == "<redacted>" ? nil : ssid
        let opt = run([Bin.ipconfig, "getoption", dev, "114"]).trimmed
        info.dhcpPortalURL = isWebURL(opt) ? opt : nil
        return info
    }

    /// The network service that owns a device, such as "Wi-Fi" for en0. Users can rename services.
    static func serviceName(_ dev: String) -> String? {
        parseServiceName(run([Bin.networksetup, "-listnetworkserviceorder"]), device: dev)
    }

    /// Reads `networksetup -listnetworkserviceorder`, where each service is "(1) Name" (or "(*) Name" if disabled)
    /// followed by "(Hardware Port: …, Device: en0)".
    static func parseServiceName(_ out: String, device: String) -> String? {
        findAll(#"\((?:\d+|\*)\) ([^\n]+)\n\(Hardware Port: [^\n]*, Device: ([^)\s]*)\)"#, out)
            .first { $0[1] == device }.map { $0[0].trimmed }
    }

    /// A hardcoded DNS server on the Wi-Fi service breaks most captive portals.
    static func manualDNS(_ service: String) -> [String] { dnsServers(service) ?? [] }

    /// The manual DNS servers on a service: empty when it's automatic, nil when the setting couldn't be read.
    static func dnsServers(_ service: String) -> [String]? {
        parseDNSServers(run([Bin.networksetup, "-getdnsservers", service]))
    }

    static func parseDNSServers(_ output: String) -> [String]? {
        let out = output.trimmed
        if out.hasPrefix("There aren't any") { return [] }
        let lines = out.split(separator: "\n").map { String($0).trimmed }
        guard !lines.isEmpty, lines.allSatisfy({ first(#"^([\d.:a-fA-F]+)$"#, $0) != nil }) else { return nil }
        return lines
    }

    static func resolvers() -> [String] {
        let block = run([Bin.scutil, "--dns"]).components(separatedBy: "resolver #2")[0]
        return findAll(#"nameserver\[\d+\]\s*:\s*(\S+)"#, block).map { $0[0] }
    }

    static func airportNetwork() -> String? {
        first(#"Current Wi-Fi Network:\s*(.+)"#, run([Bin.networksetup, "-getairportnetwork", wifiDevice()]))?.trimmed
    }

    static func arpEntry(_ ip: String) -> String? {
        run([Bin.ping, "-c", "1", "-W", "500", "-t", "1", ip], timeout: 3)
        let out = run([Bin.arp, "-n", ip])
        guard !out.contains("incomplete") else { return nil }
        return first(#"at ([0-9a-f:]{11,17})"#, out, .caseInsensitive)
    }

    static func pingMs(_ ip: String) -> Double? {
        let out = run([Bin.ping, "-c", "2", "-W", "800", "-t", "3", ip], timeout: 8)
        return first(#"= [\d.]+/([\d.]+)/"#, out).flatMap(Double.init)
    }
}
