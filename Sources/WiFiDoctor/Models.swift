import Foundation

/// The two marks the app shows, plus a neutral one for things that weren't checked or couldn't be told.
enum Status: String, Codable, Sendable {
    case ok, problem, neutral

    /// The mark used in plain text, such as the saved report.
    var mark: String {
        switch self {
        case .ok: "✓"
        case .problem: "⚠"
        case .neutral: "–"
        }
    }
}

struct TCPResult: Codable, Sendable {
    var ok: Bool
    var ms: Int
}

struct TLSResult: Codable, Sendable {
    var ok: Bool
    var ms: Int
    var detail: String
    /// Something answered but couldn't prove its identity, as when a network intercepts traffic.
    var intercepted = false
}

struct DNSResult: Codable, Sendable {
    var ok = false
    var ips: [String] = []
    var rcode: Int?
    var error: String?
    /// Replies ignored because they didn't answer the question asked.
    var rejected = 0
}

struct HTTPResult: Codable, Sendable {
    var name = ""
    var host: String
    var path: String
    var status: Int?
    var location: String?
    var body = ""
    var server: String?
    var error: String?
    var viaIP: String?
    /// true = intercepted, false = clean, nil = could not tell.
    var hijacked: Bool?
}

struct LinkInfo: Codable, Sendable {
    var active = false
    var ipv4: String?
    var netmask: String?
    var ipv6Global: [String] = []
}

struct DHCPInfo: Codable, Sendable {
    var state: String?
    var router: String?
    var dhcpDNS: [String] = []
    var leaseExpires: String?
    var ssid: String?
    var dhcpPortalURL: String?
}

struct RelayInfo: Codable, Sendable {
    var present = false
    var statusCode: Int?
    var statusLabel = "unknown"
    var networkName: String?
    var networkStatus: Int?
    var daemonRunning = false
}

struct Tests: Codable, Sendable {
    var dnsReal: [String] = []
    var dnsBogus: [String] = []
    var tlsCf: TLSResult?
    var tlsQuad9: TLSResult?
    var rawHttps: TCPResult?
    var rawDnsTcp: TCPResult?
    var relayTcp: TCPResult?
    var netDnsReal: DNSResult?
    var netDnsBogus: DNSResult?
    var gw80: TCPResult?
    var gw443: TCPResult?
    var gw53: TCPResult?
    var probes: [HTTPResult] = []
    var gwArp: String?
    var gwPing: Double?
    var gwHttp: HTTPResult?
    /// DNS replies ignored across every direct query, because they didn't answer the question asked.
    var dnsRejected = 0
}

struct Diagnosis: Codable, Sendable {
    var time = ""
    var checked = Date()
    var device = "en0"
    /// The network service for `device`. DNS settings belong to the service, which can be renamed.
    var service = "Wi-Fi"
    var routeInterface: String?
    var link = LinkInfo()
    var dhcp = DHCPInfo()
    var resolvers: [String] = []
    var manualDNS: [String] = []
    var relay = RelayInfo()
    var ssid: String?
    var ssidSource: String?
    var gateway: String?
    var networkDNS: [String] = []
    var tests = Tests()
    var portalURL: String?
    var portalSource: String?

    // Set by Verdict.
    var situation: Situation = .unclear
    var state: Status = .neutral
    var headline = ""
    var detail = ""
    /// Shown on the main screen, because they change what you should do.
    var warnings: [String] = []
    /// Every fix worth trying, best first; the Fixes list puts these at the top.
    var suggested: [Fix] = []
    /// The main screen's buttons.
    var primary: Fix?
    var secondary: Fix?
}
