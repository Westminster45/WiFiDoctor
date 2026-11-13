import Foundation

enum Bin {
    static let route = "/sbin/route"
    static let networksetup = "/usr/sbin/networksetup"
    static let ifconfig = "/sbin/ifconfig"
    static let ipconfig = "/usr/sbin/ipconfig"
    static let scutil = "/usr/sbin/scutil"
    static let arp = "/usr/sbin/arp"
    static let ping = "/sbin/ping"
    static let networkQuality = "/usr/bin/networkQuality"
    static let pgrep = "/usr/bin/pgrep"
    static let open = "/usr/bin/open"
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let osascript = "/usr/bin/osascript"
}

/// A value that is set once from another thread; `wait` blocks until then or the timeout.
final class Latch<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var value: T?
    private var done = false

    func fulfil(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        value = v
        done = true
        sem.signal()
    }

    func wait(_ timeout: Double) -> T? {
        lock.lock()
        if done { defer { lock.unlock() }; return value }
        lock.unlock()
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return done ? value : nil
    }
}

/// Starts work on a background thread straight away; `get` waits for it, like a Python future.
final class Job<T>: @unchecked Sendable {
    private let latch = Latch<T>()

    init(_ work: @escaping () -> T) {
        let latch = latch
        DispatchQueue.global(qos: .userInitiated).async { latch.fulfil(work()) }
    }

    func get(_ timeout: Double) -> T? { latch.wait(timeout) }
}

/// Runs a command, returning its exit code and stdout+stderr. Never throws.
func runStatus(_ cmd: [String], timeout: Double = 6) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd[0])
    p.arguments = Array(cmd.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let reader = Job { pipe.fileHandleForReading.readDataToEndOfFile() }
    guard let data = reader.get(timeout) else {
        p.terminate()
        return (-1, reader.get(1).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Like `runStatus`, but hands over each line of output as it arrives. Returns all the output. Blocking.
func runLines(_ cmd: [String], timeout: Double, onLine: (String) -> Void) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd[0])
    p.arguments = Array(cmd.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    let handle = pipe.fileHandleForReading
    var all = Data(), pending = Data()
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        all.append(chunk)
        pending.append(chunk)
        // Carriage returns too: tools that redraw a line in place end it with one.
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            onLine(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...end)
        }
    }
    if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    p.waitUntilExit()
    return String(decoding: all, as: UTF8.self)
}

@discardableResult
func run(_ cmd: [String], timeout: Double = 6) -> String { runStatus(cmd, timeout: timeout).output }

/// Runs a shell command as root via the standard macOS password dialog.
func runAsAdmin(_ shell: String) -> (ok: Bool, output: String) {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let r = runStatus([Bin.osascript, "-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 300)
    return (r.code == 0, r.output.trimmed)
}

/// True only for http:// and https:// addresses with a host. Login page addresses come from the network,
/// and `open` would hand any other scheme to whichever app claims it.
func isWebURL(_ s: String) -> Bool {
    guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), u.host?.isEmpty == false else { return false }
    return scheme == "http" || scheme == "https"
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Regex helpers mirroring Python's re.search / re.findall

private func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: options)
}

/// Capture groups of the first match, or nil.
func search(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = []) -> [String]? {
    let ns = text as NSString
    guard let m = regex(pattern, options).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (1..<max(m.numberOfRanges, 2)).map { i in
        guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return "" }
        return ns.substring(with: m.range(at: i))
    }
}

/// First capture group of the first match.
func first(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = []) -> String? {
    search(pattern, text, options)?.first
}

/// First capture group of the first match, giving up with nil after `budget` seconds. For patterns run on untrusted text.
func first(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = [], budget: Double) -> String? {
    let ns = text as NSString
    let deadline = Date().addingTimeInterval(budget)
    var hit: String?
    // .reportProgress calls the block periodically during a long match, so it can be stopped.
    regex(pattern, options).enumerateMatches(in: text, options: .reportProgress, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
        if let m {
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : NSRange(location: NSNotFound, length: 0)
            hit = r.location == NSNotFound ? "" : ns.substring(with: r)
            stop.pointee = true
        } else if Date() > deadline {
            stop.pointee = true
        }
    }
    return hit
}

/// Capture groups of every match.
func findAll(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = []) -> [[String]] {
    let ns = text as NSString
    return regex(pattern, options).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (1..<max(m.numberOfRanges, 2)).map { i in
            guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return "" }
            return ns.substring(with: m.range(at: i))
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func short(_ s: String?, _ n: Int = 48) -> String {
    let s = (s ?? "None").replacingOccurrences(of: "\n", with: " ")
    return s.count <= n ? s : String(s.prefix(n - 3)) + "..."
}

/// "a", "a and b", "a, b and c".
func listText(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
}

/// A date as people read it, such as "13 Nov 2026 at 14:02" in the UK.
func dateText(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}

func timestamp(_ format: String) -> String {
    let f = DateFormatter()
    f.dateFormat = format
    return f.string(from: Date())
}
