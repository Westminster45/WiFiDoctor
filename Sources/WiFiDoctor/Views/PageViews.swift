import SwiftUI

/// The title at the top of each sidebar page.
struct PageHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.title2.bold())
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One check page: its answer, then what each check found. The saved report has the same text.
struct SectionPage: View {
    @EnvironmentObject var model: AppModel
    let id: String

    var body: some View {
        let info = Report.sectionList.first { $0.id == id }
        VStack(spacing: 0) {
            PageHeader(title: info?.title ?? "", icon: info?.icon ?? "questionmark")
            Divider()
            if let section = model.sections.first(where: { $0.id == id }) {
                // List rows, not views above the list: wrapping text outside it sends window layout into a loop.
                List {
                    SectionAnswer(section: section).listRowSeparator(.hidden)
                    ForEach(section.findings) { FindingRow(finding: $0) }
                }
            } else {
                ProgressView("Checking your connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct InfoPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Connection Information", icon: "info.circle")
            Divider()
            if let d = model.diagnosis {
                List(Report.information(d)) { item in
                    LabeledContent(item.label) { Text(item.value).textSelection(.enabled) }
                }
            } else {
                ProgressView("Checking your connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct FixesPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Fixes", icon: "wrench.and.screwdriver")
            Divider()
            List {
                Text("Suggested fixes for this network come first. Fixes that change a network setting ask before they run.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(model.orderedFixes) { FixRow(fix: $0) }
            }
        }
    }
}

struct SectionAnswer: View {
    let section: DetailSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let intro = section.intro {
                Text(intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: section.status.symbol).foregroundStyle(section.status.color)
                Text(section.answer).bold().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.status.symbol).foregroundStyle(finding.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.name).font(.callout.weight(.medium))
                Text(finding.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }
}

struct FixRow: View {
    @EnvironmentObject var model: AppModel
    let fix: Fix

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fix.icon).font(.title3).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fix.title).font(.body.weight(.medium))
                    if model.isSuggested(fix) {
                        Text("Suggested").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    if fix.needsPassword {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Asks for your password")
                    }
                }
                Text(fix.blurb(model.diagnosis)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.runningFix == fix {
                ProgressView().controlSize(.small)
            } else {
                Button("Run") { model.request(fix) }
                    .disabled(!fix.isAvailable(model.diagnosis) || model.diagnosis == nil || model.runningFix != nil)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Run on request, because it takes about 30 seconds and moves a lot of data.
struct SpeedTestPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageHeader(title: "Speed Test", icon: "speedometer")
                Button { Task { await model.runSpeedTest() } } label: {
                    Label(model.speed == nil ? "Run Speed Test" : "Run Again", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.speedRunning)
                .padding(.trailing, 16)
            }
            Divider()
            if model.speedRunning {
                SpeedProgressPanel(progress: model.speedProgress)
            } else if let section = model.speedSection {
                List {
                    SectionAnswer(section: section).listRowSeparator(.hidden)
                    ForEach(section.findings) { FindingRow(finding: $0) }
                }
            } else {
                List {
                    Text("Measures download and upload speed, and how quickly the router and the internet respond. It takes about 30 seconds and can use a few hundred megabytes on a fast connection.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
    }
}

struct SpeedProgressPanel: View {
    let progress: SpeedProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = progress {
                TimelineView(.periodic(from: p.phaseStart, by: 1)) { context in
                    HStack {
                        Text(p.phase == .ping ? "Step 1 of 2: How quickly the router and the internet respond"
                             : "Step 2 of 2: Download and upload speed")
                            .font(.headline)
                        Spacer()
                        Text("\(max(0, Int(context.date.timeIntervalSince(p.phaseStart)))) s")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let f = p.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if p.phase == .ping {
                    if p.hasRouter { LivePing(label: "Router", ms: p.routerMs, done: p.routerDone) }
                    LivePing(label: "Internet (\(SpeedTest.internetHost))", ms: p.internetMs, done: p.internetDone)
                }
            } else {
                Text("Starting…").font(.headline)
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LivePing: View {
    let label: String
    let ms: Double?
    let done: Int

    var body: some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            Text(ms.map { String(format: "%.0f ms", $0) } ?? "–").monospacedDigit().frame(width: 70, alignment: .trailing)
            Spacer()
            Text("Ping \(done) of \(SpeedTest.pingCount)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
