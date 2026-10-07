import SwiftUI
import AppKit

/// Curated USB/Thunderbolt debugging commands: description + Copy for all,
/// in-app Run for read-only ones (sudo commands are copy-only by design).
struct ToolboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var output: ToolOutput?

    struct Tool: Identifiable {
        let id = UUID()
        let title: String
        let command: String
        let note: String
        let runnable: Bool
    }

    struct ToolOutput: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private static let sections: [(String, [Tool])] = [
        ("Inspect", [
            Tool(title: "USB tree (IOUSB plane)",
                 command: "ioreg -p IOUSB -l -w0",
                 note: "The ground truth this app renders — full hub topology with every property.",
                 runnable: true),
            Tool(title: "USB devices, flat",
                 command: "ioreg -c IOUSBHostDevice -l -w0 | grep -E '\\+-o|idVendor|idProduct|UsbLinkSpeed'",
                 note: "Quick VID/PID/speed sweep without the full dump.",
                 runnable: true),
            Tool(title: "Thunderbolt switches",
                 command: "ioreg -c IOThunderboltSwitch -l -w0 | head -200",
                 note: "Switch chain with UIDs, route strings, NVM versions. Note: ioreg -c prints the whole tree on recent builds; kernel matching still works.",
                 runnable: true),
            Tool(title: "PCIe devices",
                 command: "ioreg -c IOPCIDevice -l -w0 | grep -E '\\+-o|IOPCITunnelled|LinkStatus|LinkCapabilities'",
                 note: "Tunneled devices carry IOPCITunnelled=Yes and a Thunderbolt Entry ID.",
                 runnable: true),
            Tool(title: "Thunderbolt profile (system_profiler)",
                 command: "system_profiler SPThunderboltDataType -json",
                 note: "Reliable here, unlike SPUSBDataType which returns [] on this machine.",
                 runnable: true),
            Tool(title: "Type-C port manager state",
                 command: "ioreg -l -w0 | grep -A4 'Port-USB-C'",
                 note: "Cable e-marker, plug orientation, tunnel state per receptacle.",
                 runnable: true),
        ]),
        ("Live logs", [
            Tool(title: "USB subsystem log stream",
                 command: "log stream --predicate 'subsystem CONTAINS \"usb\"' --style compact",
                 note: "Streams until interrupted — run in a terminal for long sessions.",
                 runnable: false),
            Tool(title: "Thunderbolt events, last 5 min",
                 command: "log show --last 5m --predicate 'eventMessage CONTAINS[c] \"thunderbolt\"' --style compact",
                 note: "Connection, authorization, and tunnel events.",
                 runnable: true),
            Tool(title: "Kernel messages (needs sudo)",
                 command: "sudo dmesg | grep -iE 'usb|thunderbolt' | tail -50",
                 note: "Enumeration failures and controller resets land here.",
                 runnable: false),
        ]),
        ("Power", [
            Tool(title: "Power management state",
                 command: "pmset -g",
                 note: "Sleep/wake settings that affect device re-enumeration.",
                 runnable: true),
            Tool(title: "USB power assertions",
                 command: "pmset -g assertions | grep -i usb",
                 note: "Which devices are holding the system awake.",
                 runnable: true),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Toolbox", systemImage: "wrench.and.screwdriver")
                    .appFont(14, weight: .semibold)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.0.uppercased())
                                .appFont(10, weight: .bold)
                                .foregroundStyle(.tertiary)
                            ForEach(section.1) { tool in
                                toolRow(tool)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 620, height: 520)
        .sheet(item: $output) { payload in
            VStack(alignment: .leading, spacing: 8) {
                Text(payload.title).appFont(12, weight: .semibold, design: .monospaced)
                ScrollView {
                    Text(payload.text.isEmpty ? "(no output)" : payload.text)
                        .appFont(10.5, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { output = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 700, height: 460)
        }
    }

    private func toolRow(_ tool: Tool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(tool.title).appFont(12, weight: .semibold)
                Spacer()
                Button("Copy") { copy(tool.command) }
                    .controlSize(.small)
                if tool.runnable {
                    Button("Run") { run(tool) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(tool.command.hasPrefix("sudo") ? "needs sudo — copy only" : "streaming — copy only")
                        .appFont(9.5)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(tool.command)
                .appFont(10.5, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Text(tool.note)
                .appFont(10)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func run(_ tool: Tool) {
        let command = tool.command
        let title = "$ \(command)"
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var text = ""
            do {
                try process.run()
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                text = String(decoding: data.prefix(200_000), as: UTF8.self)
            } catch {
                text = "failed to run: \(error)"
            }
            let final = text
            await MainActor.run { output = ToolOutput(title: title, text: final) }
        }
    }
}
