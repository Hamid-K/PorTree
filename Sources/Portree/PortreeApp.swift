import SwiftUI
import AppKit
import PortreeCore

/// A bare SwiftPM executable launches as a background process (no bundle), so
/// the delegate must promote it to a regular app or no window/Dock icon
/// appears under `swift run`. Harmless in the bundled .app, so it stays.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PortreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless mode: `portree --dump` prints the full snapshot as JSON and
        // exits — used for scripting and for verifying the data layer without
        // a window.
        if CommandLine.arguments.contains("--dump") {
            let snapshot = Snapshot(usbRoots: USBTopologyBuilder.build(), tbRoots: TBTopologyBuilder.build())
            if let data = try? Exporters.json(snapshot) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Portree") {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
