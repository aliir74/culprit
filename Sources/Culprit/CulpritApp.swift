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
            Text(model.menuBarTitle)
                .monospacedDigit()
                .foregroundStyle(model.severity)
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

    /// Nothing Culprit paused may outlive it. A crash skips this, which is what the
    /// record on disk and the resume at launch are for.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !CommandLine.arguments.contains("--snapshot") else { return }
            Model.shared.resumeAllNow()
        }
    }
}

/// `Culprit --snapshot out.png`: take two readings, render the panel to a PNG, and exit.
/// Used to check the UI without clicking the menu bar.
@MainActor
enum Snapshotter {
    static func run(to path: String) {
        Task {
            let model = Model.shared
            model.showRecordedPauses()
            await model.refresh()
            try? await Task.sleep(for: .seconds(2))
            await model.refresh()
            let view = PanelView(model: model, flat: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
