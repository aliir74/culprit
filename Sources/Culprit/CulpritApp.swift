import AppKit
import SwiftUI

@main
struct CulpritApp: App {
    @StateObject private var model = Model.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Sampling starts at launch rather than when the panel first opens, so the sparklines
/// already have history the first time you look.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
               index + 1 < CommandLine.arguments.count {
                Snapshotter.run(to: CommandLine.arguments[index + 1])
            } else {
                Model.shared.start()
            }
        }
    }
}

/// `Culprit --snapshot out.png`: take a few readings, render the panel to a PNG, and exit.
/// Every menu bar style goes to `out-menubar.png`, on a light and a dark bar.
/// Used to check the UI without clicking the menu bar.
@MainActor
enum Snapshotter {
    static func run(to path: String) {
        Task {
            let model = Model.shared
            // Several readings, so the menu bar graph has a line to draw.
            for _ in 0..<6 {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            let view = PanelView(model: model, flat: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            write(view, to: path)
            let strip = HStack(spacing: 0) {
                ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(IndicatorStyle.allCases) { style in
                            HStack {
                                Text(style.title).frame(width: 100, alignment: .leading)
                                MenuBarLabel(model: model, style: style)
                            }
                        }
                    }
                    .padding(12)
                    .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.92))
                    .environment(\.colorScheme, scheme)
                    .foregroundStyle(scheme == .dark ? .white : .black)
                }
            }
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            write(strip, to: base + "-menubar.png")
            NSApp.terminate(nil)
        }
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
