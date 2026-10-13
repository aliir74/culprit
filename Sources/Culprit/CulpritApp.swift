import SwiftUI

@main
struct CulpritApp: App {
    var body: some Scene {
        MenuBarExtra("Culprit", systemImage: "flame") {
            Text("Culprit")
        }
        .menuBarExtraStyle(.window)
    }
}
