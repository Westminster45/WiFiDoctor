import AppKit
import Foundation

struct FixResult: Identifiable {
    let id = UUID()
    let fix: Fix
    let ok: Bool
    let message: String
    /// The password prompt was cancelled, so nothing happened and there's nothing to report.
    var cancelled = false
}

/// Everything the app can do to the network or open for you, in the Fixes list's order.
enum Fix: String, Codable, CaseIterable, Identifiable, Sendable {
    case dnsauto, portal, apple, router, relay, flush, renew, cycle, dns, wifi

    var id: String { rawValue }

    /// Button and menu text, in Apple's title style.
    var title: String {
        switch self {
        case .dnsauto: "Switch DNS to Automatic"
        case .portal: "Open Login Page"
        case .apple: "Show macOS Login Window"
        case .router: "Open Router Page"
        case .relay: "Open Private Relay Settings"
        case .flush: "Clear DNS Cache"
        case .renew: "Ask for a New IP Address"
        case .cycle: "Turn WiFi Off and On"
        case .dns: "Use Public DNS Servers"
        case .wifi: "Open WiFi Settings"
        }
    }

    /// One or two sentences saying what the fix does.
    func blurb(_ d: Diagnosis?) -> String {
        switch self {
        case .dnsauto:
            "Removes the DNS servers set on your Mac, so it uses the ones the network provides. This applies to every WiFi network."
        case .portal:
            d?.portalURL.map { "Opens \(short($0, 60)). It uses Firefox, Chrome or Brave if you have one, because Private Relay in Safari can stop login pages loading." }
                ?? "The network hasn't given a login page address."
        case .apple:
            "Opens captive.apple.com, which makes macOS show its login window if the network has a login page."
        case .router:
            d?.gateway.map { "Opens http://\($0), the router's own page. Some networks put their login page there." }
                ?? "The router's address isn't known."
        case .relay:
            "Opens Network settings. Turning off Limit IP Address Tracking for this network stops Private Relay using it."
        case .flush:
            "Clears the website addresses your Mac has already looked up, so it looks them up again."
        case .renew:
            "Asks the network for a new IP address."
        case .cycle:
            "Turns WiFi off for two seconds and back on. Your Mac rejoins the same network."
        case .dns:
            "Sets your Mac to use Cloudflare (1.1.1.1) and Google (8.8.8.8) for DNS on every WiFi network. Don't use this on a network with a login page until you've logged in."
        case .wifi:
            "Opens WiFi settings, where you can choose a network."
        }
    }

    var icon: String {
        switch self {
        case .dnsauto: "arrow.uturn.backward.circle"
        case .portal: "safari"
        case .apple: "rectangle.and.hand.point.up.left"
        case .router: "wifi.router"
        case .relay: "lock.shield"
        case .flush: "arrow.triangle.2.circlepath"
        case .renew: "arrow.clockwise.circle"
        case .cycle: "power"
        case .dns: "server.rack"
        case .wifi: "wifi"
        }
    }

    /// Browsers that ignore iCloud Private Relay, in order of preference.
    static let relayFreeBrowsers = [("Firefox", "org.mozilla.firefox"), ("Chrome", "com.google.Chrome"), ("Brave", "com.brave.Browser")]

    var needsPassword: Bool { [.dnsauto, .flush, .renew, .dns].contains(self) }

    /// Asked about before running: needs a password or briefly drops the connection.
    var needsConfirm: Bool { needsPassword || self == .cycle }

    /// The text of the question asked before running.
    func confirmMessage(_ d: Diagnosis?) -> String {
        var parts = [blurb(d)]
        if self == .cycle { parts.append("You'll be offline for a few seconds.") }
        if needsPassword { parts.append("macOS will ask for your password.") }
        return parts.joined(separator: " ")
    }

    func isAvailable(_ d: Diagnosis?) -> Bool {
        switch self {
        case .portal: d?.portalURL != nil
        case .router: d?.gateway != nil
        default: true
        }
    }

    /// Blocking; call off the main thread.
    func perform(_ d: Diagnosis) -> FixResult {
        func done(_ ok: Bool, _ message: String) -> FixResult { FixResult(fix: self, ok: ok, message: message) }
        /// `check` runs after the command and returns a problem, or nil if the change really happened.
        func admin(_ shell: String, _ success: String, check: (() -> String?)? = nil) -> FixResult {
            let r = runAsAdmin(shell)
            guard r.ok else {
                if r.output.contains("-128") { return FixResult(fix: self, ok: false, message: "Cancelled.", cancelled: true) }
                return done(false, "The change wasn't made. macOS said: \(r.output)")
            }
            if let problem = check?() { return done(false, problem) }
            return done(true, success)
        }
        let service = shellQuote(d.service)
        /// Reads the DNS setting back, since networksetup can report success without changing anything.
        func expectDNS(_ want: [String]) -> () -> String? {
            {
                guard let now = SystemInfo.dnsServers(d.service) else {
                    return "The command ran, but the DNS setting for \"\(d.service)\" couldn't be read back, so it may not have changed."
                }
                if now == want { return nil }
                let shown = now.isEmpty ? "automatic" : listText(now)
                return "The command ran, but DNS on \"\(d.service)\" is still \(shown)."
            }
        }
        switch self {
        case .dnsauto:
            return admin("/usr/sbin/networksetup -setdnsservers \(service) empty && /usr/bin/dscacheutil -flushcache",
                         "DNS is now automatic.", check: expectDNS([]))
        case .portal:
            guard let url = d.portalURL else { return done(false, "The network hasn't given a login page address.") }
            guard isWebURL(url) else { return done(false, "\(url) isn't a web address, so it can't be opened.") }
            // Only Safari uses Private Relay, so other browsers load portals Safari won't.
            for (name, id) in Fix.relayFreeBrowsers where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                if runStatus([Bin.open, "-b", id, url]).code == 0 {
                    return done(true, "Opened \(url) in \(name).")
                }
            }
            let r = runStatus([Bin.open, url])
            return r.code == 0 ? done(true, "Opened \(url).") : done(false, "\(url) couldn't be opened. macOS said: \(r.output.trimmed)")
        case .apple:
            run([Bin.open, "http://captive.apple.com/hotspot-detect.html"])
            return done(true, "Opened captive.apple.com.")
        case .router:
            guard let gw = d.gateway else { return done(false, "The router's address isn't known.") }
            run([Bin.open, "http://\(gw)"])
            return done(true, "Opened http://\(gw).")
        case .relay:
            run([Bin.open, "x-apple.systempreferences:com.apple.Network-Settings.extension"])
            return done(true, "Opened Network settings.")
        case .flush:
            return admin("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder", "The DNS cache is cleared.")
        case .renew:
            return admin("/usr/sbin/ipconfig set \(shellQuote(d.device)) DHCP", "Asked the network for a new IP address.")
        case .cycle:
            run([Bin.networksetup, "-setairportpower", d.device, "off"])
            Thread.sleep(forTimeInterval: 2)
            run([Bin.networksetup, "-setairportpower", d.device, "on"])
            return done(true, "Turned WiFi off and on.")
        case .dns:
            return admin("/usr/sbin/networksetup -setdnsservers \(service) 1.1.1.1 8.8.8.8 && /usr/bin/dscacheutil -flushcache",
                         "DNS is now 1.1.1.1 and 8.8.8.8.", check: expectDNS(["1.1.1.1", "8.8.8.8"]))
        case .wifi:
            run([Bin.open, "x-apple.systempreferences:com.apple.wifi-settings-extension"])
            return done(true, "Opened WiFi settings.")
        }
    }
}
