import Foundation
import Network

let probeTimeout = 6.0

private let netQueue = DispatchQueue(label: "wifidoc.net", attributes: .concurrent)

private func elapsed(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

private enum Outcome {
    case ready
    case failed(NWError)
}

private func params(tls: NWProtocolTLS.Options? = nil, timeout: Double) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
    let p = NWParameters(tls: tls, tcp: tcp)
    p.preferNoProxies = true
    return p
}

/// Starts a connection and waits until it is ready, fails, or times out (nil).
private func connect(_ conn: NWConnection, _ timeout: Double) -> Outcome? {
    let latch = Latch<Outcome>()
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready: latch.fulfil(.ready)
        case .failed(let e), .waiting(let e): latch.fulfil(.failed(e))
        default: break
        }
    }
    conn.start(queue: netQueue)
    return latch.wait(timeout)
}

private func endpoint(_ host: String, _ port: UInt16) -> (NWEndpoint.Host, NWEndpoint.Port) {
    (NWEndpoint.Host(host), NWEndpoint.Port(rawValue: port)!)
}

// MARK: - Reachability

func tcpProbe(_ host: String, _ port: UInt16, timeout: Double = 3) -> TCPResult {
    let start = Date()
    let (h, p) = endpoint(host, port)
    let conn = NWConnection(host: h, port: p, using: params(timeout: timeout))
    defer { conn.cancel() }
    if case .ready? = connect(conn, timeout) { return TCPResult(ok: true, ms: elapsed(start)) }
    return TCPResult(ok: false, ms: elapsed(start))
}

/// Proof of *real* internet: a captive portal can accept a TCP connection,
/// but it cannot present a valid certificate for someone else's hostname.
func tlsProbe(_ ip: String, _ hostname: String, port: UInt16 = 443, timeout: Double = 5) -> TLSResult {
    let start = Date()
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, hostname)
    let (h, p) = endpoint(ip, port)
    let conn = NWConnection(host: h, port: p, using: params(tls: tls, timeout: timeout))
    defer { conn.cancel() }
    switch connect(conn, timeout) {
    case .ready?:
        var version = "TLS"
        if let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            switch sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata) {
            case .TLSv13: version = "TLSv1.3"
            case .TLSv12: version = "TLSv1.2"
            default: break
            }
        }
        return TLSResult(ok: true, ms: elapsed(start), detail: version)
    case .failed(let e)?:
        if case .tls = e {
            return TLSResult(ok: false, ms: elapsed(start),
                             detail: "TLS rejected (\(short(e.debugDescription, 40)))", intercepted: true)
        }
        return TLSResult(ok: false, ms: elapsed(start), detail: "no connection (\(short(e.debugDescription, 40)))")
    case nil:
        return TLSResult(ok: false, ms: elapsed(start), detail: "no connection (timed out)")
    }
}

// MARK: - DNS

/// Resolve via the system resolver, with a hard timeout.
func dnsLookup(_ name: String, timeout: Double = 3) -> [String] {
    Job { systemLookup(name) }.get(timeout) ?? []
}

private func systemLookup(_ name: String) -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &res) == 0, let head = res else { return [] }
    defer { freeaddrinfo(head) }
    var ips = Set<String>()
    var cur: UnsafeMutablePointer<addrinfo>? = head
    while let ai = cur {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            ips.insert(String(cString: host))
        }
        cur = ai.pointee.ai_next
    }
    return ips.sorted()
}

func buildDNSQuery(id: UInt16, name: String) -> [UInt8] {
    var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") {
        let bytes = Array(label.utf8)
        q.append(UInt8(bytes.count))
        q += bytes
    }
    q += [0, 0, 1, 0, 1]  // root, type A, class IN
    return q
}

func parseDNSResponse(_ data: [UInt8]) -> DNSResult {
    var res = DNSResult()
    guard data.count >= 12 else { res.error = "short reply"; return res }
    func u16(_ i: Int) -> Int { Int(data[i]) << 8 | Int(data[i + 1]) }
    let flags = u16(2), qd = u16(4), an = u16(6)
    res.rcode = flags & 0xF
    res.ok = true
    var p = 12
    for _ in 0..<qd {
        while p < data.count && data[p] != 0 { p += Int(data[p]) + 1 }
        p += 5
    }
    for _ in 0..<an {
        if p >= data.count { break }
        if data[p] & 0xC0 == 0xC0 {
            p += 2
        } else {
            while p < data.count && data[p] != 0 { p += Int(data[p]) + 1 }
            p += 1
        }
        if p + 10 > data.count { break }
        let rtype = u16(p), rdlen = u16(p + 8)
        p += 10
        if rtype == 1 && rdlen == 4 && p + 4 <= data.count {
            res.ips.append("\(data[p]).\(data[p + 1]).\(data[p + 2]).\(data[p + 3])")
        }
        p += rdlen
    }
    return res
}

private func asciiLower(_ b: UInt8) -> UInt8 { (65...90).contains(b) ? b + 32 : b }

/// True if `reply` answers `query`: the same ID, marked as a response, and the same question.
/// Names are compared without regard to case, since DNS names are case-insensitive and some resolvers change it.
func dnsReplyMatches(_ reply: [UInt8], query: [UInt8]) -> Bool {
    guard query.count >= 12, reply.count >= query.count else { return false }
    guard reply[0] == query[0], reply[1] == query[1], reply[2] & 0x80 != 0 else { return false }
    guard reply[4] == query[4], reply[5] == query[5] else { return false }
    return (12..<query.count).allSatisfy { asciiLower(reply[$0]) == asciiLower(query[$0]) }
}

/// Ask one specific DNS server directly, bypassing the system resolver.
/// This is how the network's own resolver is tested when a manual DNS override has broken everything else.
/// The reply comes from the network, so anything that doesn't answer this query is ignored, not trusted.
func dnsQuery(_ server: String, _ name: String, timeout: Double = 2.5) -> DNSResult {
    var res = DNSResult()
    let q = buildDNSQuery(id: .random(in: 0...0xFFFF), name: name)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(53).bigEndian
    guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { res.error = "not an IPv4 address"; return res }
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { res.error = String(cString: strerror(errno)); return res }
    defer { close(fd) }
    // Connected, so the kernel drops packets from any other address or port, and reports a refusal straight away.
    let linked = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard linked == 0 else { res.error = String(cString: strerror(errno)); return res }
    guard send(fd, q, q.count, 0) >= 0 else { res.error = String(cString: strerror(errno)); return res }

    // Keep listening past replies that don't match, so a forged packet can't stand in for the real answer or block it.
    let deadline = Date().addingTimeInterval(timeout)
    var buf = [UInt8](repeating: 0, count: 2048)
    var rejected = 0
    while true {
        // A zero timeout would mean wait forever, so never go below a millisecond.
        let us = max(1000, Int(deadline.timeIntervalSinceNow * 1_000_000))
        guard deadline.timeIntervalSinceNow > 0 else { res.error = "timed out"; break }
        var tv = timeval(tv_sec: us / 1_000_000, tv_usec: Int32(us % 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0 {
            if errno == EINTR { continue }
            res.error = (errno == EAGAIN || errno == EWOULDBLOCK) ? "timed out" : String(cString: strerror(errno))
            break
        }
        let reply = Array(buf[0..<n])
        if dnsReplyMatches(reply, query: q) {
            res = parseDNSResponse(reply)
            break
        }
        rejected += 1
    }
    res.rejected = rejected
    return res
}

// MARK: - Captive portal probes

let cnsUserAgent = "CaptiveNetworkSupport-390.90.1 wispr"

struct ProbeSpec {
    let name, host, path: String
    let status: Int
    let body: String?
}

let probeSpecs = [
    ProbeSpec(name: "Apple", host: "captive.apple.com", path: "/hotspot-detect.html", status: 200, body: "Success"),
    ProbeSpec(name: "Cloudflare", host: "cp.cloudflare.com", path: "/generate_204", status: 204, body: nil),
    ProbeSpec(name: "Google", host: "www.gstatic.com", path: "/generate_204", status: 204, body: nil),
]

/// Raw HTTP/1.1 GET. `connectIP` reaches a host without system DNS,
/// because a broken resolver must not blind portal detection.
func httpGet(_ host: String, _ path: String, connectIP: String? = nil, port: UInt16 = 80, timeout: Double = probeTimeout) -> HTTPResult {
    var out = HTTPResult(host: host, path: path, viaIP: connectIP)
    let (h, p) = endpoint(connectIP ?? host, port)
    let conn = NWConnection(host: h, port: p, using: params(timeout: timeout))
    defer { conn.cancel() }
    switch connect(conn, timeout) {
    case .ready?: break
    case .failed(let e)?: out.error = e.debugDescription; return out
    case nil: out.error = "timed out"; return out
    }
    let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(cnsUserAgent)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })

    final class Buffer: @unchecked Sendable { var data = Data() }
    let buf = Buffer()
    let latch = Latch<String?>()  // nil = complete, otherwise an error
    func next() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let data { buf.data.append(data) }
            if let error { latch.fulfil(error.debugDescription) }
            else if isComplete || buf.data.count >= 65536 { latch.fulfil(nil) }
            else { next() }
        }
    }
    next()
    guard let result = latch.wait(timeout) else { out.error = "timed out"; return out }
    if let err = result { out.error = err; return out }
    return parseHTTP(buf.data, into: out)
}

func parseHTTP(_ raw: Data, into result: HTTPResult) -> HTTPResult {
    var out = result
    guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
        out.error = "no complete HTTP response"
        return out
    }
    let head = String(decoding: raw[raw.startIndex..<sep.lowerBound], as: UTF8.self)
    var body = Data(raw[sep.upperBound...])
    let lines = head.components(separatedBy: "\r\n")
    out.status = first(#"^HTTP/\d\.\d (\d{3})"#, lines[0]).flatMap(Int.init)
    var headers: [String: String] = [:]
    for l in lines.dropFirst() {
        guard let colon = l.firstIndex(of: ":") else { continue }
        headers[String(l[..<colon]).trimmed.lowercased()] = String(l[l.index(after: colon)...]).trimmed
    }
    out.location = headers["location"]
    out.server = headers["server"]
    if headers["transfer-encoding"]?.lowercased() == "chunked" { body = dechunk(body) }
    out.body = String(decoding: body.prefix(20000), as: UTF8.self)
    return out
}

func dechunk(_ body: Data) -> Data {
    let b = [UInt8](body)
    var out = [UInt8](), p = 0
    while p < b.count {
        guard let nl = (p..<max(p, b.count - 1)).first(where: { b[$0] == 13 && b[$0 + 1] == 10 }) else { break }
        let sizeField = String(decoding: b[p..<nl], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
        // The size comes from the network: a negative or huge one must not overflow or invert the range.
        guard let n = Int(sizeField.trimmed, radix: 16), n >= 0 else { break }
        if n == 0 { break }
        let start = nl + 2
        guard n <= b.count - start else { out += b[start...]; break }
        out += b[start..<start + n]
        p = start + n + 2
    }
    return out.isEmpty ? body : Data(out)
}

/// true = intercepted, false = clean, nil = could not tell.
func judge(_ probe: HTTPResult, _ spec: ProbeSpec) -> Bool? {
    guard probe.error == nil, let status = probe.status else { return nil }
    if [301, 302, 303, 307, 308].contains(status) { return true }
    if status != spec.status { return true }
    if let body = spec.body, !probe.body.contains(body) { return true }
    return false
}

private let portalPatterns = [
    #"<meta[^>]+http-equiv=["']?refresh["']?[^>]+url=["']?([^"'>\s]+)"#,
    #"window\.location(?:\.href|\.replace\()?\s*=?\s*["']([^"']+)["']"#,
    #"<form[^>]+action=["']([^"']+)["']"#,
    #"<a[^>]+href=["'](https?://[^"']+)["']"#,
]

private let portalWords = ["login", "portal", "auth", "wifi", "hotspot", "welcome", "capport"]

/// Seconds each pattern may spend on a page. The page comes from the network, and a crafted one can make a pattern backtrack for minutes.
private let patternBudget = 0.5

func extractPortalURL(_ probe: HTTPResult) -> (url: String, source: String)? {
    if let loc = probe.location { return (loc, "HTTP redirect") }
    for pat in portalPatterns {
        if let u = first(pat, probe.body, .caseInsensitive, budget: patternBudget)?.trimmed, !u.isEmpty,
           !u.lowercased().hasPrefix("javascript:"), !u.hasPrefix("#"), !u.lowercased().hasPrefix("mailto:") {
            return (u, "page content")
        }
    }
    // Any absolute link with a login word after the scheme. Found in two steps, because one
    // pattern with the words in the middle backtracks badly on long pages.
    for m in findAll(#"(https?://[^\s"'<>]+)"#, probe.body, .caseInsensitive) {
        let u = m[0], lower = u.lowercased()
        let rest = lower.dropFirst(lower.hasPrefix("https://") ? 9 : 8)
        if portalWords.contains(where: { rest.contains($0) }) { return (u, "page content") }
    }
    return nil
}
