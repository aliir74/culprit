import AppKit
import SwiftUI

/// How the menu bar shows machine load. Chosen in the gear menu; core columns by default.
enum IndicatorStyle: String, CaseIterable, Identifiable {
    case cores, graph, ring, culprit, number

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cores: "Core columns"
        case .graph: "History graph"
        case .ring: "Ring"
        case .culprit: "Busiest app"
        case .number: "Percentage"
        }
    }
}

/// The menu bar only takes a Text or an Image, so every style except the percentage is
/// drawn into a bitmap. The bitmap is not a template, so the macOS menu bar keeps its colour.
struct MenuBarLabel: View {
    @ObservedObject var model: Model
    /// Set by `--snapshot` to draw every style; the menu bar follows the setting.
    var style: IndicatorStyle?

    var body: some View {
        if let header = model.data?.header, let busy = header.busyPercent {
            switch style ?? model.indicator {
            case .number:
                Text("\(Int(busy.rounded()))%").monospacedDigit()
            case .culprit:
                if let icon = model.busiestAppIcon {
                    picture(CulpritMark(icon: icon, busy: busy, color: model.severity))
                } else {
                    Image(systemName: "magnifyingglass")
                }
            case .cores:
                picture(CoreColumns(busyCores: header.busyCores ?? 0,
                                    cpuCount: header.cpuCount, color: model.severity))
            case .graph:
                picture(LoadGraph(values: model.machineHistory, color: model.severity))
            case .ring:
                picture(LoadRing(busy: busy, color: model.severity,
                                 overloaded: model.severity == .red))
            }
        } else {
            Text("—")
        }
    }

    private func picture(_ content: some View) -> Image {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return Image(systemName: "questionmark") }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

private enum Indicator {
    static let height: CGFloat = 16
    /// Readable on both a light and a dark menu bar.
    static let track = Color.gray.opacity(0.35)
}

struct CoreColumns: View {
    let busyCores: Double
    let cpuCount: Int
    let color: Color

    var body: some View {
        // Past 16 cores the columns stop being readable, so each column stands for several.
        let columns = min(max(cpuCount, 1), 16)
        let busy = busyCores * Double(columns) / Double(max(cpuCount, 1))
        HStack(spacing: 1) {
            ForEach(0..<columns, id: \.self) { index in
                let fill = min(max(busy - Double(index), 0), 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(Indicator.track)
                    Capsule().fill(color).frame(height: Indicator.height * fill)
                }
                .frame(width: 2.4, height: Indicator.height)
            }
        }
    }
}

struct LoadGraph: View {
    /// Whole-machine percentages, oldest first.
    let values: [Double]
    let color: Color
    var slots = 24

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                         with: .color(Indicator.track.opacity(0.6)))
            guard values.count > 1 else { return }
            // Fixed slots, newest at the right edge, so a short history does not stretch.
            let step = size.width / CGFloat(slots - 1)
            let start = CGFloat(slots - values.count) * step
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + CGFloat(index) * step,
                                    y: size.height - 1 - CGFloat(min(value, 100) / 100) * (size.height - 2))
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.35)))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
        }
        .frame(width: 36, height: Indicator.height)
    }
}

struct LoadRing: View {
    let busy: Double
    let color: Color
    /// Threads are queueing well past the core count: the centre fills in.
    let overloaded: Bool

    var body: some View {
        ZStack {
            if overloaded { Circle().fill(color.opacity(0.35)) }
            Circle().stroke(Indicator.track, lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: min(busy, 100) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.1)
        .frame(width: Indicator.height, height: Indicator.height)
    }
}

struct CulpritMark: View {
    let icon: NSImage
    let busy: Double
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: icon).resizable().frame(width: Indicator.height, height: Indicator.height)
            ZStack(alignment: .bottom) {
                Capsule().fill(Indicator.track)
                Capsule().fill(color).frame(height: Indicator.height * min(busy, 100) / 100)
            }
            .frame(width: 3, height: Indicator.height)
        }
    }
}
