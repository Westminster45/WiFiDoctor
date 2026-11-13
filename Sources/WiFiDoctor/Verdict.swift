import Foundation

/// What is wrong, as one of a fixed set of situations. The Overview, the steps and the check pages all follow it.
enum Situation: String, Codable, Sendable {
    case noWifi, noAddress, routerUnreachable, dnsBlocksLogin, login, loginLikely, dnsFailing, noInternet, relayBlocked, online, unclear

    var needsLogin: Bool { [.dnsBlocksLogin, .login, .loginLikely].contains(self) }
}

/// Facts read from the test results. The verdict, the steps and the check pages all use these, so they can't disagree.
extension Diagnosis {
    var selfAssigned: Bool { link.ipv4?.hasPrefix("169.254.") ?? false }
    var hasIP: Bool { link.ipv4 != nil && !selfAssigned }
    var wifiOK: Bool { link.active && hasIP }
    var routerOK: Bool {
        tests.gwArp != nil || tests.gw80?.ok == true || tests.gw443?.ok == true || tests.gw53?.ok == true
    }
    /// A verified secure connection to a public server worked, which a login page can't fake.
    var secureOK: Bool { tests.tlsCf?.ok == true || tests.tlsQuad9?.ok == true }
    var intercepted: Bool { tests.tlsCf?.intercepted == true || tests.tlsQuad9?.intercepted == true }
    var probesClean: Bool { tests.probes.contains { $0.hijacked == false } }
    var probesHijacked: Bool { tests.probes.contains { $0.hijacked == true } }
    /// A verified connection worked, or the connection tests loaded and none was intercepted.
    var internetOK: Bool { secureOK || (probesClean && !probesHijacked) }
    var dnsWorks: Bool { !tests.dnsReal.isEmpty }
    var dnsHijack: Bool { !tests.dnsBogus.isEmpty }
    var networkDNSWorks: Bool { !(tests.netDnsReal?.ips.isEmpty ?? true) }
    /// The specific trap: a DNS server set on the Mac that the network won't let through.
    var manualDNSBlocks: Bool { !manualDNS.isEmpty && !dnsWorks && networkDNSWorks }
    var relayOn: Bool { relay.statusCode == 5 }
    var relayBlocked: Bool { relayOn && !(tests.relayTcp?.ok ?? false) }
}

/// Works out the situation, the main screen's text and buttons, and the order of the fixes.
enum Verdict {
    static func apply(to d: inout Diagnosis) {
        let manual = listText(d.manualDNS)
        let situation: Situation
        let headline: String, detail: String
        var actions: [Fix] = []

        if !d.link.active {
            situation = .noWifi
            headline = "Your Mac isn't connected to WiFi."
            detail = "Join a network in WiFi settings. WiFi Doctor will check it as soon as your Mac connects."
            actions = [.wifi]
        } else if !d.hasIP {
            situation = .noAddress
            headline = "The network hasn't given your Mac an IP address."
            let using = d.selfAssigned ? "Your Mac is using \(d.link.ipv4 ?? ""), an address it gave itself, which can't reach the router or the internet."
                : "Without one, your Mac can't reach the router or the internet."
            detail = using + " Asking the network for a new IP address often fixes this."
            actions = [.renew, .cycle]
        } else if !d.routerOK {
            situation = .routerUnreachable
            headline = "Your Mac can't reach the router."
            detail = "Your Mac is connected to the WiFi, but the router isn't responding. Turning WiFi off and on, or moving closer to the router, may help."
            actions = [.cycle, .renew]
        } else if d.manualDNSBlocks {
            situation = .dnsBlocksLogin
            headline = "Your Mac's DNS setting is stopping the login page appearing."
            detail = "Your Mac is set to use \(manual) for DNS, and lookups through it are failing on this network. The network's own DNS server works. Switching DNS to automatic should let the login page appear."
            actions = [.dnsauto, .portal, .apple]
        } else if (d.portalURL != nil && !d.secureOK) || (d.probesHijacked && (d.portalURL != nil || d.dnsHijack)) {
            situation = .login
            headline = "This network needs you to log in."
            if d.portalURL != nil {
                detail = "Websites won't load until you log in on the network's login page."
                actions = [.portal, .apple, .router]
            } else {
                detail = "The network is intercepting web pages, but didn't say where its login page is. The macOS login window usually finds it."
                actions = [.apple, .router]
            }
        } else if d.probesHijacked {
            situation = .loginLikely
            headline = "This network probably needs you to log in."
            detail = "The network is changing web pages, but didn't say where its login page is. The macOS login window usually finds it."
            actions = [.apple, .router]
        } else if !d.dnsWorks && d.internetOK {
            situation = .dnsFailing
            headline = "Your Mac can't find websites, but the internet is working."
            if d.manualDNS.isEmpty {
                detail = "The network's DNS server isn't finding websites. Using public DNS servers should fix this."
                actions = [.dns, .flush]
            } else {
                detail = "Your Mac is set to use \(manual) for DNS, and lookups through it are failing. Switching DNS to automatic should fix this."
                actions = [.dnsauto, .flush]
            }
        } else if !d.internetOK {
            situation = .noInternet
            headline = "This network isn't connected to the internet."
            detail = "The router responds, but nothing beyond it does. This is usually a fault with the network. If the network has a login page, the macOS login window may find it."
            actions = [.apple, .router]
        } else if d.probesClean && d.relayBlocked {
            situation = .relayBlocked
            headline = "You're online, but this network blocks Private Relay."
            detail = "Safari and Mail may not load pages until you turn off Private Relay for this network."
            actions = [.relay]
        } else if d.probesClean {
            situation = .online
            headline = "You're online."
            detail = "WiFi Doctor's connection tests passed, so websites should load normally."
        } else {
            situation = .unclear
            headline = "WiFi Doctor couldn't work out what's wrong."
            detail = "The checks gave mixed results. The pages under Checks show what each one found."
            actions = [.apple, .router]
        }

        // Warnings change what you should do, so they go on the main screen.
        var warnings: [String] = []
        if d.tests.dnsRejected > 0 {
            warnings.append("Something on this network sent DNS replies that didn't match what WiFi Doctor asked. Be careful what you type into any login page here.")
        }
        if !d.manualDNS.isEmpty, [.login, .loginLikely, .noInternet, .unclear].contains(situation) {
            warnings.append("Your Mac is set to use \(manual) for DNS on every network. Networks with a login page often block this, which can stop the login page appearing.")
            if !actions.contains(.dnsauto) { actions.insert(.dnsauto, at: min(1, actions.count)) }
        }
        if d.relayBlocked, [.dnsBlocksLogin, .login, .loginLikely, .dnsFailing, .noInternet, .unclear].contains(situation) {
            warnings.append(situation.needsLogin
                ? "Private Relay is on, and this network blocks it. After you log in, Safari and Mail may still not load pages until you turn off Private Relay for this network."
                : "Private Relay is on, and this network blocks it, so Safari and Mail may not load pages even when the network is working.")
            if !actions.contains(.relay) { actions.append(.relay) }
        }

        d.situation = situation
        d.state = situation == .online ? .ok : .problem
        d.headline = headline
        d.detail = detail
        d.warnings = warnings
        d.suggested = actions
        switch situation {
        case .noInternet:
            // Nothing on the Mac will fix a network with no internet, so there's no main button,
            // unless a DNS server set on the Mac may be what's hiding a login page.
            d.primary = actions.contains(.dnsauto) ? .dnsauto : nil
            d.secondary = actions.first
        case .dnsBlocksLogin:
            // Once DNS is fixed the checks run again and offer the login page, so one button is enough.
            d.primary = actions.first
            d.secondary = nil
        default:
            d.primary = actions.first
            d.secondary = actions.dropFirst().first
        }
    }
}
