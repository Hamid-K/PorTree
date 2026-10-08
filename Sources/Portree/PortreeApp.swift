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
        // Headless mode — flags combine, one registry capture serves all:
        //   portree --dump                          JSON snapshot on stdout
        //   portree --export-graph graph.png        graph canvas only
        //   portree --export-screenshot shot.png    composed full-app view
        let args = CommandLine.arguments
        func path(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
            return args[index + 1]
        }
        let wantsDump = args.contains("--dump")
        let graphPath = path(after: "--export-graph")
        let shotPath = path(after: "--export-screenshot")
        let fromPath = path(after: "--from-snapshot")
        if wantsDump || graphPath != nil || shotPath != nil {
            let store = AppStore.shared
            var loaded: Snapshot?
            if let fromPath {
                // Render a SAVED topology (e.g. a --dump edited for
                // screenshot redaction) instead of capturing live.
                guard let data = FileManager.default.contents(atPath: fromPath),
                      let snapshot = try? Exporters.decodeSnapshot(data) else {
                    FileHandle.standardError.write(Data("could not load snapshot at \(fromPath)\n".utf8))
                    exit(1)
                }
                loaded = snapshot
            }
            store.prepareHeadlessScreenshot(using: loaded)
            var failed = false
            if wantsDump {
                if let snapshot = store.snapshot, let data = try? Exporters.json(snapshot) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    failed = true
                }
            }
            if let graphPath {
                let ok = GraphImageExporter.writePNG(store: store, to: URL(fileURLWithPath: graphPath))
                FileHandle.standardError.write(Data((ok ? "wrote \(graphPath)\n" : "graph export failed\n").utf8))
                failed = failed || !ok
            }
            if let shotPath {
                let ok = ScreenshotComposer.export(to: URL(fileURLWithPath: shotPath))
                FileHandle.standardError.write(Data((ok ? "wrote \(shotPath)\n" : "screenshot export failed\n").utf8))
                failed = failed || !ok
            }
            exit(failed ? 1 : 0)
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
                Button("Export Graph as PNG") { GraphImageExporter.export(store: AppStore.shared, as: .png) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Export Graph as JPEG") { GraphImageExporter.export(store: AppStore.shared, as: .jpeg) }
                Button("Toolbox") { AppStore.shared.toolboxShown.toggle() }
                    .keyboardShortcut("t")
                Button("Record Throughput") { AppStore.shared.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Find Next Match") { AppStore.shared.nextSearchHit() }
                    .keyboardShortcut("g")
                Divider()
                Button("Expand All") { AppStore.shared.expandAll() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Collapse All") { AppStore.shared.collapseAll() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Expand All Tags") { AppStore.shared.expandAllTags() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                Button("Collapse All Tags") { AppStore.shared.collapseAllTags() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            }
            CommandGroup(after: .sidebar) {
                // Through zoomAround so the viewport center stays put.
                Button("Zoom In") { AppStore.shared.zoomAround(factor: 1.2) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { AppStore.shared.zoomAround(factor: 1 / 1.2) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { AppStore.shared.zoomAround(factor: 1.0 / AppStore.shared.zoom) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Increase Font Size") { AppStore.shared.adjustFontScale(by: 0.05) }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                Button("Decrease Font Size") { AppStore.shared.adjustFontScale(by: -0.05) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                Button("Default Font Size") { AppStore.shared.resetFontScale() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }
}
