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

        // Topology can change across sleep without surviving notifications.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppStore.shared.rescanSilently() }
        }
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
            let snapshot = Snapshot.capture()
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
                .environment(AppStore.shared)
        }
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandMenu("Devices") {
                Button("Rescan") { AppStore.shared.refresh() }
                    .keyboardShortcut("r")
                Button("Export Snapshot as JSON") { AppStore.shared.exportSnapshot() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Toolbox") { AppStore.shared.toolboxShown.toggle() }
                    .keyboardShortcut("t")
                Button("Record Throughput") { AppStore.shared.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Expand All") { AppStore.shared.expandAll() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Collapse All") { AppStore.shared.collapseAll() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            }
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { AppStore.shared.zoom = min(2.0, AppStore.shared.zoom * 1.2) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { AppStore.shared.zoom = max(0.25, AppStore.shared.zoom / 1.2) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { AppStore.shared.zoom = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
