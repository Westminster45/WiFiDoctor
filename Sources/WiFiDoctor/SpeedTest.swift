import Foundation

struct PingStats: Sendable, Equatable {
    var sent = 0
    var received = 0
    var lossPercent = 100.0
    /// Round-trip times in ms; nil when nothing came back.
    var min, avg, max, jitter: Double?
}

struct ThroughputStats: Sendable, Equatable {
    var downloadMbps, uploadMbps: Double?
    /// Round trips per minute under load, as Apple reports it. Higher is better.
    var responsivenessRPM: Double?
    var idleRTT: Double?
    var interface: String?
}

struct SpeedProgress: Sendable {
    enum Phase: Sendable { case ping, throughput }
    /// Counts updates, so a late one arriving on the main thread cannot overwrite a newer one.
    var step = 0
    var phase = Phase.ping
    var phaseStart = Date()
    var hasRouter: Bool
    var routerDone = 0, internetDone = 0
    /// Latest round trip in ms.
    var routerMs, internetMs: Double?

    /// How far through the current phase, or nil when it can't be told.
    var fraction: Double? {
        guard phase == .ping else { return nil }
        let total = SpeedTest.pingCount * (hasRouter ? 2 : 1)
        return Double(routerDone + internetDone) / Double(total)
    }
}

/// Progress shared by the threads of one run; every change is reported as a snapshot.
final class LiveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var state: SpeedProgress
    private let report: @Sendable (SpeedProgress) -> Void

    init(_ initial: SpeedProgress, _ report: @escaping @Sendable (SpeedProgress) -> Void) {
        state = initial
        self.report = report
    }

    func update(_ change: (inout SpeedProgress) -> Void) {
        lock.lock()
        change(&state)
        state.step += 1
        let snapshot = state
        lock.unlock()
        report(snapshot)
    }
}

struct SpeedResult: Sendable {
    var date = Date()
    var routerPing: PingStats?
    var internetPing: PingStats?
    var throughput: ThroughputStats?
    var error: String?
}

/// On-demand speed and response-time checks. Kept out of the diagnosis because it takes about 30 seconds and moves a lot of data.
enum SpeedTest {
    static let internetHost = "1.1.1.1"

    static let pingCount = 20

    /// Blocking; call off the main thread. `report` is called from background threads as the test moves along.
    static func measure(gateway: String?, report: @escaping @Sendable (SpeedProgress) -> Void = { _ in }) -> SpeedResult {
        var r = SpeedResult()
        let live = LiveProgress(SpeedProgress(hasRouter: gateway != nil), report)
        // Pings first: run alongside the speed test they would measure the load, not the line.
        let gwJob = gateway.map { g in Job { ping(g) { ms, done in live.update { $0.routerMs = ms ?? $0.routerMs; $0.routerDone = max($0.routerDone, done) } } } }
        let netJob = Job { ping(internetHost) { ms, done in live.update { $0.internetMs = ms ?? $0.internetMs; $0.internetDone = max($0.internetDone, done) } } }
        r.routerPing = gwJob?.get(20) ?? nil
        r.internetPing = netJob.get(20) ?? nil
        live.update { $0.phase = .throughput; $0.phaseStart = Date() }
        let out = runStatus([Bin.networkQuality, "-c"], timeout: 90)
        if let t = parseNetworkQuality(out.output) {
            r.throughput = t
        } else {
            r.error = out.output.trimmed.isEmpty ? "networkQuality did not finish" : short(out.output.trimmed, 160)
        }
        return r
    }

    /// `onReply` gets each reply's round trip (nil for a timeout) and how many packets are done so far.
    static func ping(_ host: String, onReply: (Double?, Int) -> Void) -> PingStats? {
        let out = runLines([Bin.ping, "-c", "\(pingCount)", "-i", "0.2", "-W", "1000", "-t", "10", host], timeout: 15) { line in
            if let reply = parsePingLine(line) { onReply(reply.ms, min(reply.seq + 1, pingCount)) }
        }
        return parsePing(out)
    }

    /// One line of `ping` output: a reply ("icmp_seq=3 … time=14.1 ms") or a timeout ("Request timeout for icmp_seq 3").
    static func parsePingLine(_ line: String) -> (seq: Int, ms: Double?)? {
        guard let seq = first(#"icmp_seq[= ](\d+)"#, line).flatMap(Int.init) else { return nil }
        return (seq, first(#"time=([\d.]+) ms"#, line).flatMap(Double.init))
    }

    /// Reads the summary lines of macOS `ping`. nil when there is no summary at all.
    static func parsePing(_ out: String) -> PingStats? {
        guard let counts = search(#"(\d+) packets transmitted, (\d+) (?:packets )?received, ([\d.]+)% packet loss"#, out),
              let sent = Int(counts[0]), let received = Int(counts[1]), let loss = Double(counts[2]) else { return nil }
        var s = PingStats(sent: sent, received: received, lossPercent: loss)
        if let rtt = search(#"min/avg/max/(?:std-dev|stddev) = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)"#, out) {
            let v = rtt.map { Double($0) }
            (s.min, s.avg, s.max, s.jitter) = (v[0], v[1], v[2], v[3])
        }
        return s
    }

    /// Reads `networkQuality -c` JSON. Key names differ between macOS versions, so every field is optional.
    static func parseNetworkQuality(_ out: String) -> ThroughputStats? {
        guard let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any] else { return nil }
        func num(_ key: String) -> Double? { (obj[key] as? NSNumber)?.doubleValue }
        let t = ThroughputStats(downloadMbps: num("dl_throughput").map { $0 / 1_000_000 },
                                uploadMbps: num("ul_throughput").map { $0 / 1_000_000 },
                                responsivenessRPM: num("responsiveness") ?? num("dl_responsiveness"),
                                idleRTT: num("base_rtt"),
                                interface: obj["interface_name"] as? String)
        return t.downloadMbps == nil && t.uploadMbps == nil ? nil : t
    }

    // MARK: - Results, in the same form as the check pages

    /// Below these, the answer says the connection is slow.
    static let slowDownload = 5.0, slowUpload = 1.0, slowResponsiveness = 200.0
    static let slowRouterPing = 50.0, slowInternetPing = 150.0

    static func section(_ r: SpeedResult, needsLogin: Bool) -> DetailSection {
        var f: [Finding] = []
        var problems: [String] = []
        func add(_ name: String, _ text: String, problem: String?, status: Status? = nil) {
            f.append(Finding(status: status ?? (problem == nil ? .ok : .problem), name: name, text: text))
            if let problem { problems.append(problem) }
        }
        if let t = r.throughput {
            if let d = t.downloadMbps { add("Download speed", "\(mbps(d)).", problem: d < slowDownload ? "download speed is slow" : nil) }
            if let u = t.uploadMbps { add("Upload speed", "\(mbps(u)).", problem: u < slowUpload ? "upload speed is slow" : nil) }
            if let rpm = t.responsivenessRPM {
                add("Responsiveness", String(format: "%.0f round trips a minute while the connection is busy. Higher is better.", rpm),
                    problem: rpm < slowResponsiveness ? "it slows down a lot when it's busy" : nil)
            }
            if let rtt = t.idleRTT { add("Response time when idle", String(format: "%.0f ms.", rtt), problem: nil) }
        }
        if let p = r.routerPing {
            if p.avg == nil {
                // Many routers are set not to answer pings, so silence here isn't a fault.
                add("Ping to the router", "\(p.sent) pings, none answered. Many routers are set not to answer pings.",
                    problem: nil, status: .neutral)
            } else {
                add("Ping to the router", pingText(p), problem: pingProblem(p, slowAbove: slowRouterPing, "the router"))
            }
        }
        if let p = r.internetPing {
            add("Ping to the internet (\(internetHost))", pingText(p), problem: pingProblem(p, slowAbove: slowInternetPing, "the internet"))
        }

        let status: Status, answer: String
        if let error = r.error {
            status = .problem
            answer = needsLogin ? "The speed test couldn't reach the internet. Log in on the login page first, then run it again."
                : "The speed test didn't finish. macOS said: \(short(error, 120))"
        } else if problems.isEmpty {
            status = .ok
            answer = "Speeds and response times are good enough for browsing, streaming and video calls."
        } else {
            status = .problem
            answer = "Your connection works, but \(listText(problems))."
        }
        return DetailSection(id: "speed", title: "Speed Test", icon: "speedometer", intro: "Measured \(dateText(r.date)).",
                             status: status, answer: answer, findings: f)
    }

    static func mbps(_ v: Double) -> String { String(format: v < 10 ? "%.1f Mbit/s" : "%.0f Mbit/s", v) }

    static func pingText(_ p: PingStats) -> String {
        guard let avg = p.avg else { return "\(p.sent) pings, none answered." }
        let lost = p.sent - p.received
        return "\(p.sent) pings, \(lost == 0 ? "none" : "\(lost)") lost. "
            + String(format: "Average %.0f ms, varying by %.1f ms (fastest %.0f ms, slowest %.0f ms).", avg, p.jitter ?? 0, p.min ?? 0, p.max ?? 0)
    }

    static func pingProblem(_ p: PingStats, slowAbove: Double, _ target: String) -> String? {
        guard let avg = p.avg else { return "\(target) didn't answer any pings" }
        if p.received < p.sent { return "some pings to \(target) were lost" }
        if avg > slowAbove { return "\(target) is slow to respond" }
        return nil
    }
}
