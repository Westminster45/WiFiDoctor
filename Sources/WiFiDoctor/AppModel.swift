import AppKit
import Foundation
import Network
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var diagnosis: Diagnosis?
    /// The check pages for the current diagnosis.
    @Published var sections: [DetailSection] = []
    @Published var running = false
    @Published var runningFix: Fix?
    /// After the login page is opened, the app checks every few seconds until you're online.
    @Published var waitingForLogin = false
    @Published var speed: SpeedResult?
    @Published var speedRunning = false
    @Published var speedProgress: SpeedProgress?

    /// The Speed Test page, once a test has run.
    var speedSection: DetailSection? {
        speed.map { SpeedTest.section($0, needsLogin: diagnosis?.situation.needsLogin ?? false) }
    }

    /// How long to keep checking for a completed login.
    static let loginWait: TimeInterval = 300

    private var runAgain = false
    private let location = LocationAccess()
    private let monitor = NetworkMonitor()
    private var waitTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?

    init() {
        location.onGranted = { [weak self] in
            Task { @MainActor in
                // Only worth a re-run if the name was missing.
                if self?.diagnosis?.ssid == nil { await self?.rerun() }
            }
        }
        monitor.onChange = { [weak self] in
            Task { @MainActor in self?.networkChanged() }
        }
    }

    func start() async {
        // The window's task runs again if the window is reopened.
        guard diagnosis == nil, !running else { return }
        if location.canAsk { location.request() }
        monitor.start()
        await rerun()
    }

    /// Runs every check. A request while checks are running runs them once more afterwards.
    func rerun() async {
        if running { runAgain = true; return }
        running = true
        repeat {
            runAgain = false
            let d = await Task.detached { Doctor.diagnose() }.value
            diagnosis = d
            sections = Report.details(d)
        } while runAgain
        running = false
        if waitingForLogin, let d = diagnosis, !d.situation.needsLogin { stopWaiting() }
    }

    func runSpeedTest() async {
        guard !speedRunning else { return }
        speedRunning = true
        speedProgress = nil
        let gw = diagnosis?.gateway
        speed = await Task.detached {
            SpeedTest.measure(gateway: gw) { p in
                Task { @MainActor [weak self] in
                    guard let self, self.speedRunning, p.step > (self.speedProgress?.step ?? -1) else { return }
                    self.speedProgress = p
                }
            }
        }.value
        speedRunning = false
        speedProgress = nil
    }

    /// Suggested fixes first, then the rest in menu order.
    var orderedFixes: [Fix] {
        let suggested = diagnosis?.suggested ?? []
        return suggested + Fix.allCases.filter { !suggested.contains($0) }
    }

    func isSuggested(_ fix: Fix) -> Bool { diagnosis?.suggested.contains(fix) ?? false }

    /// Asks first if the fix needs a password or drops the connection, then runs it.
    func request(_ fix: Fix) {
        guard diagnosis != nil, runningFix == nil else { return }
        if fix.needsConfirm {
            let alert = NSAlert()
            alert.messageText = "\(fix.title)?"
            alert.informativeText = fix.confirmMessage(diagnosis)
            alert.addButton(withTitle: fix.title)
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await perform(fix) }
    }

    private func perform(_ fix: Fix) async {
        guard let d = diagnosis, runningFix == nil else { return }
        runningFix = fix
        let result = await Task.detached { fix.perform(d) }.value
        runningFix = nil
        guard result.ok else {
            if !result.cancelled {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(fix.title) didn't work."
                alert.informativeText = result.message
                alert.runModal()
            }
            return
        }
        // Successes need no message: the checks run again and the main screen changes.
        switch fix {
        case .portal, .apple, .router:
            if d.situation != .online && d.situation != .relayBlocked { waitForLogin() }
        case .renew, .cycle:
            // Give the Mac time to rejoin the network.
            try? await Task.sleep(for: .seconds(5))
            await rerun()
        case .dnsauto, .dns, .flush:
            await rerun()
        case .relay, .wifi:
            break
        }
    }

    private func waitForLogin() {
        waitTask?.cancel()
        waitingForLogin = true
        waitTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(AppModel.loginWait)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { return }
                if await Task.detached(operation: { Doctor.quickOnline() }).value { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.waitingForLogin = false
            self.waitTask = nil
            await self.rerun()
        }
    }

    func stopWaiting() {
        waitTask?.cancel()
        waitTask = nil
        waitingForLogin = false
    }

    /// Waits for the network to settle, then checks it.
    private func networkChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.rerun()
        }
    }

    func saveReport() {
        guard let d = diagnosis else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WiFi Doctor Report \(timestamp("yyyy-MM-dd HH.mm")).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Report.text(d, speed: speed).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Reports when the Mac joins, leaves or changes network, so the checks can run again.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wifidoc.path")
    private var last: String?
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = "\(path.status) \(path.availableInterfaces.map(\.name)) \(path.gateways.map { "\($0)" })"
            if let last = self.last, last != now { self.onChange?() }
            self.last = now
        }
        monitor.start(queue: queue)
    }
}
