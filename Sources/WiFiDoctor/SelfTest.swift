import Foundation

/// Headless checks usable without XCTest: `WiFiDoctor --selftest`.
enum SelfTest {
    static func run() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { fails.append(name) } }

        // DNS packet building and parsing.
        let q = buildDNSQuery(id: 0x1234, name: "captive.apple.com")
        check(q.prefix(12) == [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0], "dns header")
        var question: [UInt8] = [7]
        question += Array("captive".utf8)
        question += [5]
        question += Array("apple".utf8)
        question += [3]
        question += Array("com".utf8)
        question += [0, 0, 1, 0, 1]
        check(Array(q[12...]) == question, "dns question")
        var reply = q
        reply[2] = 0x81; reply[3] = 0x80; reply[7] = 2
        for ip in [[17, 253, 77, 201], [17, 253, 77, 202]] as [[UInt8]] {
            reply += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4] + ip
        }
        let parsed = parseDNSResponse(reply)
        check(parsed.ok && parsed.rcode == 0 && parsed.ips == ["17.253.77.201", "17.253.77.202"], "dns answer parse")
        var nx = q
        nx[3] = 0x83
        check(parseDNSResponse(nx).rcode == 3 && parseDNSResponse(nx).ips.isEmpty, "dns nxdomain")
        check(parseDNSResponse([1, 2, 3]).error == "short reply", "dns short reply")

        // Only replies that answer the query are accepted.
        func asReply(_ query: [UInt8]) -> [UInt8] { var r = query; r[2] |= 0x80; return r }
        check(dnsReplyMatches(reply, query: q), "dns reply matches")
        var wrongID = reply
        wrongID[1] ^= 0xFF
        check(!dnsReplyMatches(wrongID, query: q), "dns reply with wrong ID rejected")
        check(!dnsReplyMatches(q, query: q), "dns query is not a reply")
        check(!dnsReplyMatches(asReply(buildDNSQuery(id: 0x1234, name: "capture.apple.com")), query: q), "dns reply to another name rejected")
        check(dnsReplyMatches(asReply(buildDNSQuery(id: 0x1234, name: "CAPTIVE.Apple.com")), query: q), "dns reply name case ignored")
        check(!dnsReplyMatches(Array(reply.prefix(20)), query: q), "truncated dns reply rejected")

        // The network service and its DNS setting, as networksetup prints them.
        let order = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en7)
        (*) Bob's Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (3) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """
        check(SystemInfo.parseServiceName(order, device: "en0") == "Bob's Wi-Fi", "renamed disabled service found")
        check(SystemInfo.parseServiceName(order, device: "en7") == "USB 10/100/1000 LAN", "service found by device")
        check(SystemInfo.parseServiceName(order, device: "en9") == nil, "unknown device has no service")
        check(shellQuote("Bob's Wi-Fi") == #"'Bob'\''s Wi-Fi'"#, "service name quoted for the shell")
        check(SystemInfo.parseDNSServers("There aren't any DNS Servers set on Wi-Fi.\n") == [], "automatic DNS read")
        check(SystemInfo.parseDNSServers("1.1.1.1\n8.8.8.8\n") == ["1.1.1.1", "8.8.8.8"], "manual DNS read")
        check(SystemInfo.parseDNSServers("Bob is not a recognized network service.\n** Error: The parameters were not valid.") == nil,
              "networksetup error is not read as automatic")
        check(SystemInfo.parseDNSServers("") == nil, "no output is not read as automatic")

        // HTTP parsing and portal detection.
        let apple = probeSpecs[0], cf = probeSpecs[1]
        func http(_ raw: String) -> HTTPResult { parseHTTP(Data(raw.utf8), into: HTTPResult(host: "h", path: "/")) }
        let ok = http("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<HTML><BODY>Success</BODY></HTML>")
        check(ok.status == 200 && judge(ok, apple) == false, "clean apple probe")
        let redirect = http("HTTP/1.1 302 Found\r\nLocation: http://portal.example/login\r\n\r\n")
        check(judge(redirect, apple) == true && extractPortalURL(redirect)?.url == "http://portal.example/login", "redirect portal")
        check(judge(http("HTTP/1.1 200 OK\r\n\r\nwelcome"), cf) == true, "204 expected, got 200")
        check(judge(http("HTTP/1.1 204 No Content\r\n\r\n"), cf) == false, "clean 204")
        check(judge(HTTPResult(host: "h", path: "/", error: "timed out"), cf) == nil, "error is inconclusive")
        check(http("garbage").error == "no complete HTTP response", "incomplete response")
        func portal(_ body: String) -> String? { extractPortalURL(HTTPResult(host: "h", path: "/", body: body))?.url }
        check(portal(#"<meta http-equiv="refresh" content="0; url=http://wifi.example/a">"#) == "http://wifi.example/a", "meta refresh")
        check(portal(#"<script>window.location = "http://wifi.example/b";</script>"#) == "http://wifi.example/b", "js redirect")
        check(portal(#"<form method="post" action="/login.cgi">"#) == "/login.cgi", "form action")
        check(portal("<p>nothing here</p>") == nil, "no portal")
        let chunked = http("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        check(chunked.body == "hello world", "dechunk")
        let huge = http("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF\r\nhi\r\n")
        check(huge.body.hasPrefix("hi"), "dechunk oversized chunk")
        let negative = http("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n")
        check(negative.status == 200, "dechunk negative chunk")
        check(portal("<p>Sign in at http://portal.example/wifi-login now</p>") == "http://portal.example/wifi-login", "login word link")
        check(portal("<p>http://example.com/news</p>") == nil, "plain link is not a portal")
        let started = Date()
        _ = portal(String(repeating: "<form action=x ", count: 3000))
        check(Date().timeIntervalSince(started) < 5, "hostile page finishes")

        // Only web addresses are opened.
        check(isWebURL("http://portal.example/login") && isWebURL("HTTPS://portal.example"), "web URL accepted")
        check(!isWebURL("httpfoo://x") && !isWebURL("file:///etc/passwd") && !isWebURL("http:nohost"), "non-web URL rejected")

        // Private Relay's keyed-archive reader.
        let archived = try? NSKeyedArchiver.archivedData(
            withRootObject: ["ServiceStatus": ["PrivacyProxyServiceStatus": 5]] as NSDictionary, requiringSecureCoding: false)
        let root = archived.flatMap(Relay.unarchive)?["root"] as? [String: Any]
        check((root?["NS.keys"] as? [Any])?.first as? String == "ServiceStatus", "keyed archive UIDs")

        // Verdicts on made-up networks.
        func verdict(_ change: (inout Diagnosis) -> Void) -> Diagnosis {
            var d = onlineDiagnosis()
            change(&d)
            Verdict.apply(to: &d)
            return d
        }
        func section(_ d: Diagnosis, _ id: String) -> DetailSection? { Report.details(d).first { $0.id == id } }
        let online = verdict { _ in }
        check(online.situation == .online && online.state == .ok && online.suggested.isEmpty && online.primary == nil, "online")
        check(Report.steps(online).allSatisfy { $0.status == .ok }, "online steps all pass")
        check(section(online, "login")?.answer.contains("If it has a login page, you've already signed in") == true,
              "an online network isn't said to have no login page")
        check(Set(Report.steps(online).map(\.icon)).count == 4 && Report.placeholderSteps.map(\.name) == Report.steps(online).map(\.name),
              "each step has its own symbol")
        let trap = verdict {
            $0.manualDNS = ["1.1.1.1"]
            $0.tests.dnsReal = []
            $0.tests.probes = $0.tests.probes.map { var p = $0; p.hijacked = nil; return p }
        }
        check(trap.situation == .dnsBlocksLogin && trap.primary == .dnsauto && trap.secondary == nil, "manual DNS trap")
        let captive = verdict {
            $0.portalURL = "http://portal.example/login"
            $0.tests.tlsCf?.ok = false
            $0.tests.tlsQuad9?.ok = false
            $0.tests.probes[0].hijacked = true
        }
        check(captive.situation == .login && captive.primary == .portal && captive.secondary == .apple, "captive portal")
        let captiveSteps = Report.steps(captive)
        check(captiveSteps.map(\.status) == [.ok, .ok, .problem, .neutral] && captiveSteps[2].login, "captive portal steps")
        check(section(captive, "login")?.answer.contains("http://portal.example/login") == true, "login page named in details")
        check(section(captive, "internet")?.status == .problem, "internet not reachable behind a login page")
        let captiveManual = verdict {
            $0.portalURL = "http://portal.example/login"
            $0.tests.tlsCf?.ok = false
            $0.tests.tlsQuad9?.ok = false
            $0.tests.probes[0].hijacked = true
            $0.manualDNS = ["1.1.1.1"]
        }
        check(captiveManual.primary == .portal && captiveManual.secondary == .dnsauto && captiveManual.warnings.count == 1,
              "manual DNS warned about on a login network")
        let relay = verdict {
            $0.relay.statusCode = 5
            $0.tests.relayTcp = TCPResult(ok: false, ms: 4000)
        }
        check(relay.situation == .relayBlocked && relay.suggested == [.relay] && section(relay, "relay")?.status == .problem, "relay blocked")
        let noWifi = verdict { $0.link.active = false }
        check(noWifi.situation == .noWifi && noWifi.primary == .wifi, "no WiFi")
        check(section(noWifi, "router")?.answer == "Not checked, because your Mac isn't connected to WiFi.", "later sections skipped without WiFi")
        let noIP = verdict { $0.link.ipv4 = nil }
        check(noIP.situation == .noAddress && noIP.suggested == [.renew, .cycle], "no IP")
        let selfAssigned = verdict { $0.link.ipv4 = "169.254.3.4" }
        check(selfAssigned.situation == .noAddress && selfAssigned.detail.contains("169.254.3.4"), "self-assigned IP")
        let routerDown = verdict { $0.tests.gwArp = nil }
        check(routerDown.situation == .routerUnreachable && routerDown.primary == .cycle, "router unreachable")
        check(Report.steps(routerDown).map(\.status) == [.ok, .problem, .neutral, .neutral], "router unreachable steps")
        let dnsBroken = verdict { $0.tests.dnsReal = [] }
        check(dnsBroken.situation == .dnsFailing && dnsBroken.suggested == [.dns, .flush], "dns failing")
        check(Report.steps(dnsBroken).map(\.status) == [.ok, .ok, .ok, .problem], "dns failing steps")
        let offline = verdict {
            $0.tests.tlsCf?.ok = false
            $0.tests.tlsQuad9?.ok = false
            $0.tests.probes = $0.tests.probes.map { var p = $0; p.hijacked = nil; return p }
        }
        check(offline.situation == .noInternet && offline.primary == nil && offline.secondary == .apple, "no internet")
        let providerPages = verdict { $0.tests.dnsBogus = ["198.51.100.7"] }
        check(providerPages.situation == .online && section(providerPages, "websites")?.status == .ok,
              "made-up lookups answered on a working network")

        // Login page detection: a router's own admin redirect is not a login page while checks pass.
        let routerPage = http("HTTP/1.1 302 Found\r\nLocation: ztp/ztp_enabled.html\r\n\r\n")
        var passing = onlineDiagnosis().tests
        passing.gwHttp = routerPage
        check(Doctor.findPortal(dhcp: DHCPInfo(), tests: passing, gateway: "192.168.1.1") == nil, "router page ignored when online")
        var failing = passing
        failing.tlsCf?.ok = false
        failing.tlsQuad9?.ok = false
        failing.probes = failing.probes.map { var p = $0; p.hijacked = nil; return p }
        check(Doctor.findPortal(dhcp: DHCPInfo(), tests: failing, gateway: "192.168.1.1")?.url == "http://192.168.1.1/ztp/ztp_enabled.html",
              "router page used and made absolute when offline")
        var hijackedProbe = failing
        hijackedProbe.probes[0] = parseHTTP(Data("HTTP/1.1 302 Found\r\nLocation: /login\r\n\r\n".utf8),
                                            into: HTTPResult(host: "captive.apple.com", path: "/hotspot-detect.html"))
        hijackedProbe.probes[0].hijacked = true
        check(Doctor.findPortal(dhcp: DHCPInfo(), tests: hijackedProbe, gateway: "192.168.1.1")?.url == "http://captive.apple.com/login",
              "relative probe redirect made absolute")

        check(Report.details(online).map(\.id) == Report.sectionList.map(\.id)
              && Report.details(online).map(\.title) == Report.sectionList.map(\.title), "sidebar matches the check pages")

        // The saved report has every section, the facts and the version.
        let text = Report.text(captive)
        check(Report.details(captive).allSatisfy { text.contains("\n\($0.title)\n") }
              && text.contains("\nConnection Information\n") && text.contains("Version \(appVersion)"), "text report sections")
        check(Report.dottedMask("0xffffff00") == "255.255.255.0" && Report.dottedMask("255.255.0.0") == "255.255.0.0", "subnet mask")
        check(listText(["a"]) == "a" && listText(["a", "b", "c"]) == "a, b and c", "list text")
        check(Report.wrap("one two three", 9, first: "* ", rest: "  ") == ["* one two", "  three"], "text wrapping")

        // Speed test parsing and results.
        let pingOK = SpeedTest.parsePing("""
            --- 1.1.1.1 ping statistics ---
            20 packets transmitted, 19 packets received, 5.0% packet loss
            round-trip min/avg/max/stddev = 9.812/14.250/31.006/4.117 ms
            """)
        check(pingOK == PingStats(sent: 20, received: 19, lossPercent: 5, min: 9.812, avg: 14.25, max: 31.006, jitter: 4.117), "ping summary")
        let pingLost = SpeedTest.parsePing("20 packets transmitted, 0 packets received, 100.0% packet loss")
        check(pingLost?.lossPercent == 100 && pingLost?.avg == nil, "ping all lost")
        check(SpeedTest.parsePing("ping: cannot resolve host: Unknown host") == nil, "ping no summary")
        let pingReply = SpeedTest.parsePingLine("64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=14.123 ms")
        check(pingReply?.seq == 3 && pingReply?.ms == 14.123, "ping reply line")
        let pingTimeout = SpeedTest.parsePingLine("Request timeout for icmp_seq 7")
        check(pingTimeout?.seq == 7 && pingTimeout?.ms == nil, "ping timeout line")
        check(SpeedTest.parsePingLine("PING 1.1.1.1 (1.1.1.1): 56 data bytes") == nil, "ping header line")
        let nq = SpeedTest.parseNetworkQuality(#"{"dl_throughput":245000000,"ul_throughput":18500000,"responsiveness":1200,"base_rtt":12.5,"interface_name":"en0"}"#)
        check(nq == ThroughputStats(downloadMbps: 245, uploadMbps: 18.5, responsivenessRPM: 1200, idleRTT: 12.5, interface: "en0"), "networkQuality json")
        check(SpeedTest.parseNetworkQuality(#"{"dl_throughput":5000000,"dl_responsiveness":300}"#)?.responsivenessRPM == 300, "networkQuality older keys")
        check(SpeedTest.parseNetworkQuality(#"{"error_code":-1009}"#) == nil, "networkQuality no throughput")
        check(SpeedTest.parseNetworkQuality("Error: offline") == nil, "networkQuality not json")
        let fast = SpeedTest.section(SpeedResult(internetPing: PingStats(sent: 20, received: 20, lossPercent: 0, min: 9, avg: 12, max: 20, jitter: 2),
                                                 throughput: nq), needsLogin: false)
        check(fast.status == .ok && fast.findings.allSatisfy { $0.status == .ok }, "fast connection passes")
        let lossy = SpeedTest.section(SpeedResult(internetPing: pingOK, throughput: nq), needsLogin: false)
        check(lossy.status == .problem && lossy.answer == "Your connection works, but some pings to the internet were lost.", "lost pings reported")
        let quietRouter = SpeedTest.section(SpeedResult(routerPing: pingLost, throughput: nq), needsLogin: false)
        check(quietRouter.status == .ok && quietRouter.findings.last?.status == .neutral, "a router that ignores pings isn't a fault")
        check(SpeedTest.section(SpeedResult(internetPing: pingLost), needsLogin: false).findings.first?.status == .problem, "no internet replies is a problem")
        check(SpeedTest.section(SpeedResult(error: "offline"), needsLogin: true).answer.hasPrefix("The speed test couldn't reach the internet"),
              "speed test behind a login page")
        check(Report.text(online, speed: SpeedResult(throughput: nq)).contains("\nSpeed Test\n"), "speed test in the saved report")
        return fails
    }

    private static func onlineDiagnosis() -> Diagnosis {
        var d = Diagnosis()
        d.link = LinkInfo(active: true, ipv4: "192.168.1.20", netmask: "0xffffff00")
        d.gateway = "192.168.1.1"
        d.networkDNS = ["192.168.1.1"]
        d.tests.dnsReal = ["17.253.77.201"]
        d.tests.tlsCf = TLSResult(ok: true, ms: 20, detail: "TLSv1.3")
        d.tests.tlsQuad9 = TLSResult(ok: true, ms: 20, detail: "TLSv1.3")
        d.tests.gwArp = "aa:bb:cc:dd:ee:ff"
        d.tests.relayTcp = TCPResult(ok: true, ms: 30)
        d.tests.netDnsReal = DNSResult(ok: true, ips: ["17.253.77.201"], rcode: 0)
        d.tests.probes = probeSpecs.map { HTTPResult(name: $0.name, host: $0.host, path: $0.path, status: $0.status, hijacked: false) }
        return d
    }
}

/// `--json` and `--once`, the script's other modes.
enum CLI {
    static func handle(_ args: [String]) {
        if args.contains("--version") {
            print("WiFi Doctor \(appVersion)")
            exit(0)
        }
        if args.contains("--selftest") {
            let fails = SelfTest.run()
            print(fails.isEmpty ? "selftest OK" : "selftest FAILED: \(fails)")
            exit(fails.isEmpty ? 0 : 1)
        }
        if args.contains("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.keyEncodingStrategy = .convertToSnakeCase
            print(String(decoding: try! enc.encode(Doctor.diagnose()), as: UTF8.self))
            exit(0)
        }
        if args.contains("--once") {
            print(Report.text(Doctor.diagnose()))
            exit(0)
        }
    }
}
