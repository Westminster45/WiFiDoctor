import Foundation

/// Runs every check (about 10 seconds) and works out the verdict. Blocking; call off the main thread.
enum Doctor {
    static let bogusDomain = "wifidoc-nonexistent-8f3a2b91.example.invalid"

    static func diagnose() -> Diagnosis {
        var d = Diagnosis()
        d.time = timestamp("yyyy-MM-dd HH:mm:ss")
        d.checked = Date()
        let dev = SystemInfo.wifiDevice()
        let route = SystemInfo.defaultRoute()
        d.device = dev
        d.service = SystemInfo.serviceName(dev) ?? "Wi-Fi"
        d.routeInterface = route.iface
        d.link = SystemInfo.ifaceStatus(dev)
        d.dhcp = SystemInfo.dhcpInfo(dev)
        d.resolvers = SystemInfo.resolvers()
        d.manualDNS = SystemInfo.manualDNS(d.service)
        d.relay = Relay.state()
        (d.ssid, d.ssidSource) = NetworkName.find(dhcp: d.dhcp)
        d.gateway = route.gateway ?? d.dhcp.router
        let gw = d.gateway

        // The resolver the network wants us to use, which a manual override hides.
        var netDNS = d.dhcp.dhcpDNS.filter { !$0.isEmpty }
        if netDNS.isEmpty, let gw { netDNS = [gw] }
        d.networkDNS = netDNS

        let dnsReal = Job { dnsLookup("captive.apple.com") }
        let dnsBogus = Job { dnsLookup(bogusDomain) }
        let tlsCf = Job { tlsProbe("1.1.1.1", "one.one.one.one") }
        let tlsQuad9 = Job { tlsProbe("9.9.9.9", "dns.quad9.net") }
        let rawHttps = Job { tcpProbe("1.1.1.1", 443) }
        let rawDnsTcp = Job { tcpProbe("1.1.1.1", 53) }
        let relayTcp = Job { tcpProbe("mask.icloud.com", 443, timeout: 4) }
        let netReal = netDNS.first.map { s in Job { dnsQuery(s, "captive.apple.com") } }
        let netBogus = netDNS.first.map { s in Job { dnsQuery(s, bogusDomain) } }
        let gw80 = gw.map { g in Job { tcpProbe(g, 80) } }
        let gw443 = gw.map { g in Job { tcpProbe(g, 443) } }
        let gw53 = gw.map { g in Job { tcpProbe(g, 53) } }

        let wait = probeTimeout + 4
        var t = Tests()
        t.dnsReal = dnsReal.get(wait) ?? []
        t.dnsBogus = dnsBogus.get(wait) ?? []
        t.tlsCf = tlsCf.get(wait)
        t.tlsQuad9 = tlsQuad9.get(wait)
        t.rawHttps = rawHttps.get(wait)
        t.rawDnsTcp = rawDnsTcp.get(wait)
        t.relayTcp = relayTcp.get(wait)
        t.netDnsReal = netReal?.get(wait)
        t.netDnsBogus = netBogus?.get(wait)
        t.gw80 = gw80?.get(wait)
        t.gw443 = gw443?.get(wait)
        t.gw53 = gw53?.get(wait)

        // Portal probes. If system DNS is dead, resolve through the network's own
        // resolver and connect by IP, so a broken resolver cannot hide the portal.
        let useNetDNS = t.dnsReal.isEmpty && !(t.netDnsReal?.ips.isEmpty ?? true)
        let lookups = probeSpecs.map { spec in useNetDNS ? dnsQuery(netDNS[0], spec.host) : nil }
        t.dnsRejected = ([t.netDnsReal, t.netDnsBogus] + lookups).reduce(0) { $0 + ($1?.rejected ?? 0) }
        let probeJobs = zip(probeSpecs, lookups).map { spec, lookup in
            let ip = lookup?.ips.first
            return Job { httpGet(spec.host, spec.path, connectIP: ip) }
        }
        // Portals usually serve their login page straight off the gateway.
        let gwArp = gw.map { g in Job { SystemInfo.arpEntry(g) } }
        let gwPing = gw.map { g in Job { SystemInfo.pingMs(g) } }
        let gwHttp = gw.map { g in Job { httpGet(g, "/", timeout: 4) } }

        t.probes = zip(probeSpecs, probeJobs).map { spec, job in
            var p = job.get(probeTimeout + 3) ?? HTTPResult(host: spec.host, path: spec.path, error: "probe timed out")
            p.name = spec.name
            p.hijacked = judge(p, spec)
            return p
        }
        t.gwArp = gwArp?.get(wait) ?? nil
        t.gwPing = gwPing?.get(wait) ?? nil
        t.gwHttp = gwHttp?.get(wait)
        d.tests = t

        if let portal = findPortal(dhcp: d.dhcp, tests: t, gateway: gw) {
            (d.portalURL, d.portalSource) = (portal.url, portal.source)
        }

        Verdict.apply(to: &d)
        return d
    }

    /// A few seconds' check, used while waiting for a login: true once Apple's or Cloudflare's
    /// connection test loads normally, which is the signal macOS itself uses.
    static func quickOnline() -> Bool {
        let jobs = probeSpecs.prefix(2).map { spec in Job { judge(httpGet(spec.host, spec.path, timeout: 4), spec) } }
        return jobs.contains { $0.get(6) == false }
    }

    /// The login page address, best source first, made absolute.
    static func findPortal(dhcp: DHCPInfo, tests t: Tests, gateway: String?) -> (url: String, source: String)? {
        if let u = dhcp.dhcpPortalURL { return (u, "DHCP option 114") }
        for p in t.probes where p.hijacked == true {
            if let hit = extractPortalURL(p) { return (absolute(hit.url, base: "http://\(p.host)\(p.path)"), hit.source) }
        }
        // Most routers redirect their own page to an admin screen, so it only means a
        // login page when the connectivity checks have failed.
        let checksPass = t.probes.contains { $0.hijacked == false } && (t.tlsCf?.ok == true || t.tlsQuad9?.ok == true)
        if !checksPass, let gw = gateway, let page = t.gwHttp, let hit = extractPortalURL(page) {
            return (absolute(hit.url, base: "http://\(gw)/"), "router page, \(hit.source)")
        }
        return nil
    }

    /// Turns a relative address like "ztp/login.html" into a full URL on the server it came from.
    static func absolute(_ url: String, base: String) -> String {
        URL(string: url, relativeTo: URL(string: base))?.absoluteString ?? url
    }
}
