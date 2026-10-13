import AppKit
import ClaudeTopKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: Model
    /// ImageRenderer draws a ScrollView empty, so `--snapshot` lays the rows out flat.
    var flat = false
    @State private var expanded: Set<String> = []
    @State private var showAllAgents = false
    @State private var showAllApps = false

    init(model: Model, flat: Bool = false) {
        self.model = model
        self.flat = flat
        // A snapshot cannot press "more", so it shows every session.
        _showAllAgents = State(initialValue: flat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data = model.data {
                HeaderView(header: data.header)
                Divider()
                if flat {
                    rows(data)
                } else {
                    ScrollView { rows(data) }
                        .frame(maxHeight: 560)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            Divider()
            FooterView(model: model)
        }
        .frame(width: 380)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func rows(_ data: PanelData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            agents(data)
            LeftoversView(model: model, rows: data.leftovers, canStop: data.canStop)
            apps(data)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func agents(_ data: PanelData) -> some View {
        SectionTitle(title: "AGENTS", trailing: data.agents.isEmpty ? nil : "CPU · RAM")
        if data.agents.isEmpty {
            Text("No agent sessions running")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
        let visible = showAllAgents ? data.agents : Array(data.agents.prefix(5))
        ForEach(visible) { row in
            AgentRowView(row: row, history: model.history[row.id] ?? [],
                         expanded: expanded.contains(row.id),
                         paused: model.paused[row.id] != nil,
                         busy: model.pausing.contains(row.id),
                         canPause: data.canStop,
                         togglePause: {
                             let paused = model.paused[row.id] != nil
                             Task {
                                 if paused { await model.resume(row.key) }
                                 else { await model.pause(row.key) }
                             }
                         }) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if expanded.contains(row.id) { expanded.remove(row.id) }
                    else { expanded.insert(row.id) }
                }
            }
        }
        if data.agents.count > 5 {
            let rest = data.agents.dropFirst(5)
            MoreButton(label: showAllAgents ? "Show fewer"
                       : "\(rest.count) more · \(Fmt.cpu(rest.reduce(0) { $0 + ($1.cpu ?? 0) }))") {
                showAllAgents.toggle()
            }
        }
    }

    @ViewBuilder private func apps(_ data: PanelData) -> some View {
        SectionTitle(title: "OTHER APPS", trailing: nil)
        let visible = showAllApps ? Array(data.apps.prefix(25)) : Array(data.apps.prefix(6))
        ForEach(visible) { AppRowView(row: $0) }
        if data.apps.count > 6 {
            MoreButton(label: showAllApps ? "Show fewer" : "More apps") { showAllApps.toggle() }
        }
    }
}

// MARK: - header

struct HeaderView: View {
    let header: PanelData.Header

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(header.busyPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                Text(coresLine).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .help(explanation)
            }
            CoreBar(busyCores: header.busyCores ?? 0, cpuCount: header.cpuCount)
            HStack {
                Text("Memory \(Fmt.gb(header.memUsed)) of \(Fmt.gb(header.memTotal))")
                Spacer()
                Text("Agents: \(String(format: "%.1f", header.agentCores)) cores")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var coresLine: String {
        let cores = header.busyCores.map { String(format: "%.1f", $0) } ?? "—"
        return "\(cores) of \(header.cpuCount) cores · \(Int(header.queuedThreads.rounded())) waiting"
    }

    private var explanation: String {
        var lines = ["Rows are per core, as in Activity Monitor: 100% is one full core."]
        if let unaccounted = header.unaccountedCores {
            lines.append(String(format: "%.1f busy cores are not shown in any row: kernel time, "
                                + "sampling gaps, and processes of other users.", unaccounted))
        }
        lines.append("\(header.hiddenProcesses) of \(header.totalProcesses) processes belong to "
                     + "other users and cannot be read without root.")
        lines.append("“Waiting” is the 1-minute load average: threads ready to run.")
        return lines.joined(separator: "\n")
    }
}

struct CoreBar: View {
    let busyCores: Double
    let cpuCount: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(cpuCount, 1), id: \.self) { index in
                let fill = min(max(busyCores - Double(index), 0), 1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(Fmt.heat(busyCores / Double(max(cpuCount, 1)) * 100))
                            .frame(width: geo.size.width * fill)
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

// MARK: - rows

struct SectionTitle: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct AgentRowView: View {
    let row: PanelData.AgentRow
    let history: [Double]
    let expanded: Bool
    let paused: Bool
    let busy: Bool
    let canPause: Bool
    let togglePause: () -> Void
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIcon(bundle: row.appBundle, fallback: "terminal")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.title).fontWeight(.medium)
                        if let subtitle = row.subtitle {
                            Text("· \(subtitle)").foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    if paused || row.detail != nil {
                        HStack(spacing: 4) {
                            if paused {
                                Text("paused")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                                    .fixedSize()
                            }
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Sparkline(values: history, dimmed: paused)
                    .frame(width: 44, height: 16)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.cpu(row.cpu))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(Fmt.rowColor(row.cpu))
                    Text(Fmt.mem(row.rss))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 46, alignment: .trailing)
                pauseButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.05) : .clear)
            .onHover { hover = $0 }
            .onTapGesture(perform: toggle)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.paths.prefix(8)) { line in
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(line.display).lineLimit(1).truncationMode(.middle)
                            Text(line.names)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Fmt.cpu(line.cpu)).monospacedDigit()
                                .foregroundStyle(Fmt.rowColor(line.cpu))
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                        .onTapGesture { reveal(line.path) }
                        .help(line.path.isEmpty ? "Folder unknown" : "Show \(line.path) in Finder")
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 16)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private var pauseButton: some View {
        if busy {
            ProgressView().controlSize(.mini).frame(width: 18)
        } else {
            Button(action: togglePause) {
                Image(systemName: paused ? "play.circle.fill" : "pause.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(paused ? Color.blue : Color.secondary)
            .disabled(!canPause)
            .help(!canPause ? "The session list could not be read, so pausing is off"
                  : paused ? "Resume this session"
                  : "Pause this session and everything it started")
            .frame(width: 18)
        }
    }

    private func reveal(_ path: String) {
        guard !path.isEmpty, path != "/" else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

struct LeftoversView: View {
    @ObservedObject var model: Model
    let rows: [PanelData.LeftoverRow]
    let canStop: Bool
    @State private var open = false
    @State private var confirming = false

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("\(rows.count) leftover\(rows.count == 1 ? "" : "s")").fontWeight(.semibold)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if confirming {
                        Button("Cancel") { confirming = false }.controlSize(.small)
                        Button("Stop \(rows.count)") {
                            confirming = false
                            Task { await model.stop(rows.map(\.key)) }
                        }
                        .controlSize(.small)
                        .tint(.red)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Clean up") { confirming = true; open = true }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStop || !model.stopping.isEmpty)
                            .help(canStop ? "Stop every process and container no live session uses"
                                  : "The session list could not be read, so stopping is off")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }

                if open {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in leftover(row) }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    private var summary: String {
        let rss = rows.reduce(0) { $0 + $1.rss }
        let oldest = rows.compactMap(\.age).max()
        return "· \(Fmt.mem(rss))" + (oldest.map { " · oldest \(Fmt.age($0))" } ?? "")
    }

    private func leftover(_ row: PanelData.LeftoverRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1).truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let age = row.age {
                Text(Fmt.age(age)).font(.caption).foregroundStyle(.orange)
            }
            Text(Fmt.mem(row.rss)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
            if model.stopping.contains(row.id) {
                ProgressView().controlSize(.mini).frame(width: 22)
            } else {
                Button { Task { await model.stop([row.key]) } } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canStop)
                .help("Stop this leftover")
                .frame(width: 22)
            }
        }
        .font(.callout)
    }
}

struct AppRowView: View {
    let row: PanelData.AppRow
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundle: row.appBundle, fallback: "gearshape")
            Text(row.name).lineLimit(1)
            if row.count > 1 {
                Text("\(row.count)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Text(Fmt.mem(row.rss))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(Fmt.cpu(row.cpu))
                .fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(Fmt.rowColor(row.cpu))
                .frame(minWidth: 46, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(hover ? Color.primary.opacity(0.05) : .clear)
        .onHover { hover = $0 }
    }
}

struct MoreButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 46)
        .padding(.vertical, 4)
    }
}

struct FooterView: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack {
            Text("Every \(Int(model.interval))s · Culprit \(Fmt.cpu(model.ownCPU))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Update every", selection: $model.interval) {
                    ForEach([2.0, 3, 5, 10], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Toggle("Start at login", isOn: Binding(
                    get: { model.startsAtLogin },
                    set: { model.setStartsAtLogin($0) }))
                Divider()
                Button("Quit Culprit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - pieces

struct AppIcon: View {
    let bundle: String?
    let fallback: String

    var body: some View {
        Group {
            if let bundle, let image = IconCache.icon(for: bundle) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundle: String) -> NSImage? {
        if let hit = cache[bundle] { return hit }
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        image.size = NSSize(width: 20, height: 20)
        cache[bundle] = image
        return image
    }
}

struct Sparkline: View {
    let values: [Double]
    var dimmed = false

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, 50)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - 1 - CGFloat(value / top) * (size.height - 2))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            let color = dimmed ? Color.secondary.opacity(0.5) : Fmt.rowColor(values.last)
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

enum Fmt {
    static func cpu(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 && value > 0 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    static func mem(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fG", mb / 1024) : "\(Int(mb.rounded()))M"
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func age(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// Per-core figure: 100% is one full core.
    static func rowColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 150 { return .red }
        if value >= 50 { return .orange }
        return .primary
    }

    /// Whole-machine percentage, 0 to 100.
    static func heat(_ percent: Double) -> Color {
        if percent > 85 { return .red }
        if percent > 55 { return .orange }
        return .green
    }
}
