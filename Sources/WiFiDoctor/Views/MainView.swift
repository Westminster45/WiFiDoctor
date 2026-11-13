import SwiftUI

extension Status {
    var color: Color {
        switch self {
        case .ok: .green
        case .problem: .orange
        case .neutral: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .neutral: "minus.circle"
        }
    }
}

/// The main window: a sidebar of pages, with Overview giving the answer, and a bar along the bottom.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String? = "overview"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SidebarRow(title: "Overview", icon: "stethoscope", status: model.diagnosis?.state)
                    .tag("overview")
                Section("Checks") {
                    ForEach(Report.sectionList) { info in
                        SidebarRow(title: info.title, icon: info.icon,
                                   status: model.sections.first { $0.id == info.id }?.status)
                            .tag(info.id)
                    }
                    SidebarRow(title: "Connection Information", icon: "info.circle", status: nil)
                        .tag("info")
                }
                Section("Performance") {
                    SidebarRow(title: "Speed Test", icon: "speedometer", status: model.speedSection?.status, onDemand: true)
                        .tag("speed")
                }
                Section {
                    SidebarRow(title: "Fixes", icon: "wrench.and.screwdriver", status: nil,
                               badge: model.diagnosis?.suggested.count ?? 0)
                        .tag("fixes")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Inset inside the column, not around the split view, so lists scroll their last row clear of the bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        footer
                    }
                }
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case "fixes"?:
            FixesPage()
        case "info"?:
            InfoPage()
        case "speed"?:
            SpeedTestPage()
        case let id? where Report.sectionList.contains(where: { $0.id == id }):
            SectionPage(id: id)
        default:
            ScrollView {
                Group {
                    if let d = model.diagnosis {
                        AnswerView(diagnosis: d)
                    } else {
                        FirstCheckView()
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Refreshes "Checked 2 minutes ago" as time passes.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(statusLine(now: context.date)).font(.callout)
                }
                Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.running || model.runningFix != nil { ProgressView().controlSize(.small) }
            Button { model.saveReport() } label: {
                Label("Save Report…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.diagnosis == nil)
            Button { Task { await model.rerun() } } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(model.running || model.runningFix != nil)
            .keyboardShortcut("r", modifiers: .command)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func statusLine(now: Date) -> String {
        if model.running { return "Checking…" }
        guard let d = model.diagnosis else { return "" }
        let ago = now.timeIntervalSince(d.checked) < 60
            ? "just now" : RelativeDateTimeFormatter().localizedString(for: d.checked, relativeTo: now)
        return [d.ssid, "Checked \(ago)"].compactMap { $0 }.joined(separator: " · ")
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let icon: String
    let status: Status?
    var badge = 0
    /// Runs only when asked, so it spins for its own test rather than for the checks.
    var onDemand = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
            if badge > 0 {
                Text("\(badge)").font(.caption.bold()).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            } else if onDemand ? model.speedRunning : (model.diagnosis == nil && model.running) {
                ProgressView().controlSize(.small)
            } else if let status, status != .neutral {
                Circle().fill(status.color).frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Shown until the first checks finish.
struct FirstCheckView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AnswerPanel(tint: .secondary) {
                ProgressView().controlSize(.large)
            } text: {
                Text("Checking your connection…").font(.title2.bold())
                Text("This takes about 10 seconds.")
            } extra: {
                EmptyView()
            }
            StepsView(steps: Report.placeholderSteps, checking: true)
        }
    }
}

/// The answer, in a panel tinted by the result, so it stands apart from the steps below.
struct AnswerPanel<Icon: View, Content: View, Extra: View>: View {
    let tint: Color
    @ViewBuilder let icon: Icon
    @ViewBuilder let text: Content
    @ViewBuilder let extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                icon.frame(width: 48)
                VStack(alignment: .leading, spacing: 6) { text }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // Warnings and buttons line up with the text, not the symbol.
            VStack(alignment: .leading, spacing: 12) { extra }
                .padding(.leading, 64)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AnswerView: View {
    @EnvironmentObject var model: AppModel
    let diagnosis: Diagnosis

    var body: some View {
        let d = diagnosis
        let waiting = model.waitingForLogin
        let tint = waiting ? Color.orange : d.state.color
        VStack(alignment: .leading, spacing: 22) {
            AnswerPanel(tint: tint) {
                Image(systemName: waiting ? "hourglass" : d.state.symbol)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(tint)
            } text: {
                Text(waiting ? "Waiting for you to log in…" : d.headline)
                    .font(.title2.bold())
                Text(waiting
                     ? "Log in on the network's login page. WiFi Doctor checks every few seconds and will update this when you're online."
                     : d.detail)
            } extra: {
                ForEach(d.warnings, id: \.self) { warning in
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                buttons(d, waiting: waiting)
            }
            StepsView(steps: Report.steps(d), checking: model.running)
        }
    }

    @ViewBuilder
    private func buttons(_ d: Diagnosis, waiting: Bool) -> some View {
        let primary = d.primary.flatMap { $0.isAvailable(d) ? $0 : nil }
        let secondary = d.secondary.flatMap { $0.isAvailable(d) ? $0 : nil }
        let busy = model.running || model.runningFix != nil
        if primary != nil || secondary != nil || waiting {
            HStack(spacing: 10) {
                if let primary {
                    Button(primary.title) { model.request(primary) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
                if let secondary {
                    Button(secondary.title) { model.request(secondary) }
                        .disabled(busy)
                }
                if waiting {
                    Button("Stop Waiting") { model.stopWaiting() }
                }
            }
            .controlSize(.large)
        }
    }
}

/// WiFi, Router, Internet, Websites: how far the connection gets. Steps after the first problem are greyed out.
struct StepsView: View {
    let steps: [Step]
    let checking: Bool

    var body: some View {
        let row = HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(steps[index - 1].status == .ok ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 21)
                }
                VStack(spacing: 6) {
                    // Each step has its own symbol in a circle; the colour shows the result and the caption says it in words.
                    let tint = step.status == .neutral ? Color.secondary : step.status.color
                    ZStack {
                        Circle().fill(tint.opacity(step.status == .neutral ? 0.08 : 0.18))
                        Image(systemName: step.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(step.status == .neutral ? tint.opacity(0.5) : tint)
                    }
                    .frame(width: 44, height: 44)
                    Text(step.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(step.status == .neutral ? Color.secondary : Color.primary)
                    Text(step.caption.isEmpty ? " " : step.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 110)
            }
        }
        if checking {
            // All steps pulse together, because the checks run at the same time, not one after another.
            row.phaseAnimator([1.0, 0.35]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            row
        }
    }
}
