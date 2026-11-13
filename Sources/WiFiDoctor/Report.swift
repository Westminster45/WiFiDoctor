import Foundation

/// One thing that was checked: its name, and one sentence saying what was found.
/// ✓ means the result is what a working network gives; ⚠ means it isn't.
struct Finding: Identifiable {
    let id = UUID()
    let status: Status
    let name: String
    let text: String
}

/// One check page: its answer, then the findings behind it.
/// ✓ means this part of the connection works; ⚠ means it has a problem; – means it wasn't checked or couldn't be told.
struct DetailSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    var intro: String? = nil
    let status: Status
    let answer: String
    var findings: [Finding] = []
}

/// A plain fact about the connection, with no mark.
struct InfoItem: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// One step of the connection on the main screen. Steps after the first problem are greyed out.
struct Step: Identifiable {
    let name: String
    /// The step's own symbol, the same one its sidebar page uses. Colour, not the symbol, shows the result.
    let icon: String
    let status: Status
    let caption: String
    var login = false
    var id: String { name }
}

/// A page in the sidebar, known before any check has run.
struct SectionInfo: Identifiable {
    let id: String
    let title: String
    let icon: String
}

/// The text for the check pages and the saved report. Both use exactly the same wording.
enum Report {
    static let dnsIntro = "DNS turns website names, such as apple.com, into the IP addresses your Mac connects to."

    /// The check pages, in the order `details` returns them.
    static let sectionList = [
        SectionInfo(id: "wifi", title: "WiFi", icon: "wifi"),
        SectionInfo(id: "router", title: "Router", icon: "wifi.router"),
        SectionInfo(id: "internet", title: "Internet", icon: "globe"),
        SectionInfo(id: "websites", title: "Websites", icon: "character.book.closed"),
        SectionInfo(id: "login", title: "Login Page", icon: "door.left.hand.open"),
        SectionInfo(id: "relay", title: "Private Relay", icon: "lock.shield"),
    ]

    // MARK: - Steps

    /// The pages that are also steps on the Overview, in order.
    static let stepIDs = ["wifi", "router", "internet", "websites"]

    /// The steps before any check has finished.
    static var placeholderSteps: [Step] {
        sectionList.filter { stepIDs.contains($0.id) }.map { Step(name: $0.title, icon: $0.icon, status: .neutral, caption: "") }
    }

    static func steps(_ d: Diagnosis) -> [Step] {
        var out: [Step] = []
        var reached = true
        func add(_ id: String, _ ok: Bool, _ okCaption: String, _ problemCaption: String, login: Bool = false) {
            let info = sectionList.first { $0.id == id }
            let name = info?.title ?? id, icon = info?.icon ?? "circle"
            guard reached else { out.append(Step(name: name, icon: icon, status: .neutral, caption: "")); return }
            out.append(Step(name: name, icon: icon, status: ok ? .ok : .problem, caption: ok ? okCaption : problemCaption, login: !ok && login))
            reached = ok
        }
        add("wifi", d.wifiOK, short(d.ssid ?? "Connected", 18), d.link.active ? "No IP address" : "Not connected")
        add("router", d.routerOK, "Responding", "Not responding")
        add("internet", d.internetOK, "Reachable", d.situation.needsLogin ? "Login needed" : "Not reachable", login: d.situation.needsLogin)
        add("websites", d.dnsWorks, "Working", "Not working")
        return out
    }

    // MARK: - Check pages

    static func details(_ d: Diagnosis) -> [DetailSection] {
        // A section can't be checked once an earlier step has failed.
        let wifiBlocker: String? = !d.link.active ? "your Mac isn't connected to WiFi"
            : (d.hasIP ? nil : "your Mac doesn't have an IP address")
        let beyondBlocker: String? = wifiBlocker
            ?? (d.gateway == nil ? "the network hasn't given your Mac a router" : (d.routerOK ? nil : "the router isn't responding"))
        func skipped(_ id: String, _ title: String, _ icon: String, _ reason: String, intro: String? = nil) -> DetailSection {
            DetailSection(id: id, title: title, icon: icon, intro: intro, status: .neutral, answer: "Not checked, because \(reason).")
        }
        return [
            wifi(d),
            wifiBlocker.map { skipped("router", "Router", "wifi.router", $0) } ?? router(d),
            beyondBlocker.map { skipped("internet", "Internet", "globe", $0) } ?? internet(d),
            beyondBlocker.map { skipped("websites", "Websites", "character.book.closed", $0, intro: dnsIntro) } ?? websites(d),
            beyondBlocker.map { skipped("login", "Login Page", "door.left.hand.open", $0) } ?? login(d),
            relay(d, blocker: beyondBlocker),
        ]
    }

    static func wifi(_ d: Diagnosis) -> DetailSection {
        func section(_ status: Status, _ answer: String, _ findings: [Finding]) -> DetailSection {
            DetailSection(id: "wifi", title: "WiFi", icon: "wifi", status: status, answer: answer, findings: findings)
        }
        guard d.link.active else {
            return section(.problem, "Your Mac isn't connected to WiFi.", [Finding(status: .problem, name: "WiFi network", text: "Not connected.")])
        }
        var f = [Finding(status: .ok, name: "WiFi network", text: d.ssid.map { "Connected to \($0)." }
            ?? "Connected. macOS hides the network's name unless WiFi Doctor has Location access.")]
        if d.hasIP, let ip = d.link.ipv4 {
            f.append(Finding(status: .ok, name: "IP address", text: "The network assigned \(ip)."))
        } else if d.selfAssigned, let ip = d.link.ipv4 {
            f.append(Finding(status: .problem, name: "IP address", text: "The network hasn't assigned one. Your Mac is using \(ip), an address it gave itself."))
        } else {
            f.append(Finding(status: .problem, name: "IP address", text: "The network hasn't assigned one."))
        }
        let on = d.ssid.map { "connected to \($0)" } ?? "connected to WiFi"
        return d.hasIP
            ? section(.ok, "Your Mac is \(on) and has an IP address.", f)
            : section(.problem, "Your Mac is \(on), but the network hasn't given it an IP address.", f)
    }

    static func router(_ d: Diagnosis) -> DetailSection {
        func section(_ status: Status, _ answer: String, _ text: String) -> DetailSection {
            DetailSection(id: "router", title: "Router", icon: "wifi.router", status: status, answer: answer,
                          findings: [Finding(status: status, name: "Router", text: text)])
        }
        guard let gw = d.gateway else {
            return section(.problem, "The network hasn't told your Mac which router to use, so your Mac can't reach the internet.",
                           "None given by the network.")
        }
        guard d.routerOK else {
            return section(.problem, "The router isn't responding, so your Mac can't reach the internet.", "\(gw) didn't respond.")
        }
        let time = d.tests.gwPing.map { $0 < 1 ? " in under 1 ms" : " in \(Int($0.rounded())) ms" } ?? ""
        return section(.ok, "The router is responding.", "\(gw) responded\(time).")
    }

    static func internet(_ d: Diagnosis) -> DetailSection {
        func secure(_ r: TLSResult?, _ server: String) -> Finding {
            let name = "Secure connection to \(server)"
            guard let r else { return Finding(status: .problem, name: name, text: "Couldn't connect.") }
            if r.ok { return Finding(status: .ok, name: name, text: "Connected in \(r.ms) ms. \(server) proved its identity.") }
            if r.intercepted { return Finding(status: .problem, name: name, text: "Something answered, but couldn't prove it was \(server).") }
            return Finding(status: .problem, name: name, text: "Couldn't connect.")
        }
        let status: Status, answer: String
        if d.secureOK {
            status = .ok
            answer = "Your Mac can reach the internet."
        } else if d.internetOK {
            status = .ok
            answer = "Your Mac can reach the internet, but secure connections to Cloudflare and Quad9 failed. Some networks block them."
        } else if d.intercepted {
            status = .problem
            answer = "Your Mac can't reach the internet. Something on the network is answering in place of internet servers, which usually means you need to log in."
        } else if d.situation.needsLogin {
            status = .problem
            answer = "Your Mac can't reach the internet until you log in."
        } else {
            status = .problem
            answer = "Your Mac can't reach the internet. Nothing beyond the router is responding."
        }
        return DetailSection(id: "internet", title: "Internet", icon: "globe", status: status, answer: answer,
                             findings: [secure(d.tests.tlsCf, "Cloudflare"), secure(d.tests.tlsQuad9, "Quad9")])
    }

    static func websites(_ d: Diagnosis) -> DetailSection {
        var f: [Finding] = []
        let provided = d.dhcp.dhcpDNS
        if d.manualDNS.isEmpty {
            let inUse = d.resolvers.isEmpty ? provided : d.resolvers
            f.append(Finding(status: .ok, name: "DNS servers", text: inUse.isEmpty
                ? "Your Mac uses the DNS servers the network provides."
                : "Your Mac uses the \(inUse.count == 1 ? "one" : "ones") the network provides: \(listText(inUse))."))
        } else {
            let hurting = d.manualDNSBlocks || d.situation == .dnsFailing || d.situation.needsLogin || d.situation == .noInternet
            f.append(Finding(status: hurting ? .problem : .ok, name: "DNS servers",
                             text: "Set on your Mac: \(listText(d.manualDNS))." + (provided.isEmpty ? "" : " The network provides \(listText(provided)).")))
        }

        let real = d.tests.dnsReal.first
        let sameAsMadeUp = real.map { d.tests.dnsBogus.contains($0) } ?? false
        f.append(real.map { Finding(status: sameAsMadeUp ? .problem : .ok, name: "Looking up a real website", text: "captive.apple.com was given the address \($0).") }
            ?? Finding(status: .problem, name: "Looking up a real website", text: "captive.apple.com couldn't be found."))

        // Only worth showing when it can differ from the lookup above.
        if let nd = d.tests.netDnsReal, !d.manualDNS.isEmpty || !d.dnsWorks {
            let server = d.networkDNS.first ?? "The network's DNS server"
            let text = nd.ips.first.map { "\(server) gave captive.apple.com the address \($0)." }
                ?? (nd.ok ? "\(server) answered, but didn't give an address for captive.apple.com." : "\(server) didn't answer.")
            f.append(Finding(status: nd.ips.isEmpty ? .problem : .ok, name: "Asking the network's DNS server directly", text: text))
        }

        f.append(d.tests.dnsBogus.first.map {
            Finding(status: .problem, name: "Looking up a made-up website", text: "A website that doesn't exist was \(sameAsMadeUp ? "also " : "")given the address \($0).")
        } ?? Finding(status: .ok, name: "Looking up a made-up website", text: "A website that doesn't exist was correctly reported as not existing."))

        let n = d.tests.dnsRejected
        if n > 0 {
            f.append(Finding(status: .problem, name: "Mismatched DNS replies",
                             text: "\(n) DNS \(n == 1 ? "reply" : "replies") didn't match what WiFi Doctor asked, so \(n == 1 ? "it was" : "they were") ignored. A faulty router can cause this, and so can a device on the network sending false replies."))
        }

        let online = d.situation == .online || d.situation == .relayBlocked
        let status: Status, answer: String
        if d.manualDNSBlocks {
            status = .problem
            answer = "Your Mac can't find websites. Lookups through the DNS server set on your Mac are failing, but the network's own DNS server works."
        } else if !d.dnsWorks {
            status = .problem
            answer = "Your Mac can't find websites, because its DNS lookups are failing."
        } else if d.dnsHijack && !online {
            status = .problem
            answer = "The network is answering website lookups itself. This is common on networks that need you to log in."
        } else if d.dnsHijack {
            status = .ok
            answer = "Your Mac can find websites. The network also gives addresses for websites that don't exist, which some internet providers do to show their own pages instead of an error."
        } else {
            status = .ok
            answer = "Your Mac can find websites."
        }
        return DetailSection(id: "websites", title: "Websites", icon: "character.book.closed", intro: dnsIntro,
                             status: status, answer: answer, findings: f)
    }

    static func login(_ d: Diagnosis) -> DetailSection {
        var f: [Finding] = probeSpecs.map { (spec: ProbeSpec) -> Finding in
            let name = "\(spec.name)'s test page"
            guard let p = d.tests.probes.first(where: { $0.name == spec.name }) else {
                return Finding(status: .problem, name: name, text: "Didn't load.")
            }
            switch p.hijacked {
            case false?: return Finding(status: .ok, name: name, text: "Loaded normally.")
            case true?: return Finding(status: .problem, name: name, text: p.location.map { "Redirected to \(short($0, 70))." } ?? "Replaced with a different page.")
            case nil: return Finding(status: .problem, name: name, text: "Didn't load.")
            }
        }
        if let u = d.dhcp.dhcpPortalURL {
            f.append(Finding(status: d.situation.needsLogin ? .problem : .ok, name: "Login page address sent by the network",
                             text: "The network sent \(short(u, 70)) when your Mac joined."))
        }
        if let u = d.portalURL, d.portalSource?.hasPrefix("router page") == true {
            f.append(Finding(status: .problem, name: "Router's own page", text: "Leads to \(short(u, 70))."))
        }

        let status: Status, answer: String
        if d.situation == .dnsBlocksLogin {
            status = .problem
            answer = "The login page can't appear until your Mac's DNS setting is switched to automatic."
        } else if d.situation.needsLogin, let u = d.portalURL {
            status = .problem
            answer = "The network's login page is \(short(u, 70)). You need to log in there before you can use the internet."
        } else if d.situation.needsLogin {
            status = .problem
            answer = "The network is intercepting web pages, but didn't say where its login page is. The macOS login window usually finds it."
        } else if d.probesClean {
            // Once you've signed in, a network with a login page looks the same as one without,
            // so the answer can't say there's no login page.
            status = .ok
            if let u = d.dhcp.dhcpPortalURL {
                answer = "This network has a login page at \(short(u, 70)). It isn't asking you to log in at the moment, so you've probably already signed in."
            } else {
                answer = "This network isn't asking you to log in at the moment. If it has a login page, you've already signed in."
            }
        } else {
            status = .neutral
            answer = "WiFi Doctor couldn't tell whether this network has a login page, because its test pages didn't load."
        }
        return DetailSection(id: "login", title: "Login Page", icon: "door.left.hand.open", status: status, answer: answer, findings: f)
    }

    static func relay(_ d: Diagnosis, blocker: String?) -> DetailSection {
        var f: [Finding] = []
        let status: Status, answer: String
        if d.relay.statusCode == nil {
            status = .neutral
            answer = "WiFi Doctor couldn't tell whether Private Relay is on."
        } else if !d.relayOn {
            status = .ok
            answer = "Private Relay is off, so it isn't affecting this network."
        } else if let blocker {
            status = .neutral
            answer = "Private Relay is on. It wasn't checked, because \(blocker)."
        } else {
            let reachable = d.tests.relayTcp?.ok == true
            f.append(Finding(status: reachable ? .ok : .problem, name: "Private Relay's servers",
                             text: reachable ? "mask.icloud.com responded." : "mask.icloud.com didn't respond."))
            status = reachable ? .ok : .problem
            answer = reachable ? "Private Relay is on and working on this network."
                : "Private Relay is on, but this network blocks it, so Safari and Mail may not load pages."
        }
        return DetailSection(id: "relay", title: "Private Relay", icon: "lock.shield", status: status, answer: answer, findings: f)
    }

    /// Facts with no mark, named as macOS names them in System Settings > Wi-Fi > Details.
    static func information(_ d: Diagnosis) -> [InfoItem] {
        var r: [InfoItem] = []
        if let s = d.ssid { r.append(InfoItem(label: "WiFi network", value: s)) }
        if let ip = d.link.ipv4 { r.append(InfoItem(label: "IP address", value: ip)) }
        if let m = d.link.netmask { r.append(InfoItem(label: "Subnet mask", value: dottedMask(m))) }
        if let g = d.gateway { r.append(InfoItem(label: "Router", value: g)) }
        let dns = d.resolvers.isEmpty ? d.manualDNS : d.resolvers
        if !dns.isEmpty { r.append(InfoItem(label: "DNS servers", value: dns.joined(separator: ", "))) }
        if let v6 = d.link.ipv6Global.first { r.append(InfoItem(label: "IPv6 address", value: v6)) }
        r.append(InfoItem(label: "Checked", value: dateText(d.checked)))
        r.append(InfoItem(label: "WiFi Doctor", value: "Version \(appVersion)"))
        return r
    }

    /// ifconfig gives the subnet mask in hex, such as 0xffffff00; System Settings shows 255.255.255.0.
    static func dottedMask(_ mask: String) -> String {
        guard mask.lowercased().hasPrefix("0x"), let v = UInt32(mask.dropFirst(2), radix: 16) else { return mask }
        return [24, 16, 8, 0].map { String((v >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    // MARK: - Plain text, for Save Report and --once

    /// The saved report. A speed test, if one has run, follows the check pages.
    static func text(_ d: Diagnosis, speed: SpeedResult? = nil) -> String {
        let w = 74
        var out = ["WiFi Doctor \(appVersion)", "Checked \(dateText(d.checked))", ""]
        out += wrap(d.headline, w)
        out += wrap(d.detail, w)
        for warning in d.warnings {
            out.append("")
            out += wrap(warning, w, first: "⚠ ", rest: "  ")
        }
        if !d.suggested.isEmpty {
            out += ["", "What to Try"]
            out += d.suggested.enumerated().map { "  \($0.offset + 1). \($0.element.title)" }
        }
        var sections = details(d)
        if let speed { sections.append(SpeedTest.section(speed, needsLogin: d.situation.needsLogin)) }
        for s in sections {
            out += ["", s.title]
            if let intro = s.intro { out += wrap(intro, w) }
            out += wrap(s.answer, w, first: "\(s.status.mark) ", rest: "  ")
            for f in s.findings {
                out += wrap(f.name, w, first: "    \(f.status.mark) ", rest: "      ")
                out += wrap(f.text, w, first: "      ", rest: "      ")
            }
        }
        out += ["", "Connection Information"]
        out += information(d).map { "    " + $0.label.padding(toLength: 16, withPad: " ", startingAt: 0) + " " + $0.value }
        return out.joined(separator: "\n") + "\n"
    }

    /// Wraps at `width`, starting the first line with `first` and later lines with `rest`.
    static func wrap(_ text: String, _ width: Int, first: String = "", rest: String = "") -> [String] {
        var lines: [String] = []
        var cur = first
        var started = false
        for word in text.split(separator: " ") {
            if started && cur.count + 1 + word.count > width {
                lines.append(cur)
                cur = rest + word
            } else {
                cur += (started ? " " : "") + word
            }
            started = true
        }
        lines.append(cur)
        return lines
    }
}
