import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PortreeCore

/// One terminal session: owns the connection, the visible output, and a
/// timestamped transcript of every byte in each direction.
@MainActor
@Observable
final class SerialSession {

    enum LineEnding: String, CaseIterable, Identifiable {
        case none = "None", lf = "LF", cr = "CR", crlf = "CR+LF"
        var id: String { rawValue }
        var bytes: Data {
            switch self {
            case .none: return Data()
            case .lf: return Data([0x0A])
            case .cr: return Data([0x0D])
            case .crlf: return Data([0x0D, 0x0A])
            }
        }
    }

    struct LogEntry {
        let date: Date
        let outgoing: Bool
        let data: Data
    }

    static let baudRates = [9_600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600, 1_000_000]
    private static let outputCap = 128 * 1024
    private static let logCap = 20_000

    let path: String
    var baud = 115_200
    var lineEnding: LineEnding = .crlf
    /// Show received bytes as hex rows, and parse typed input as hex bytes.
    var hexMode = false
    private(set) var connected = false
    private(set) var error: String?
    private(set) var text = ""
    private(set) var hex = ""
    private(set) var rxBytes = 0
    private(set) var txBytes = 0
    private var hexColumn = 0
    private var log: [LogEntry] = []
    private var connection: SerialConnection?

    init(path: String) {
        self.path = path
    }

    func connect() {
        guard !connected else { return }
        error = nil
        let connection = SerialConnection(path: path)
        do {
            try connection.open(
                baud: baud,
                onData: { [weak self] data in
                    Task { @MainActor in self?.receive(data) }
                },
                onClose: { [weak self] in
                    Task { @MainActor in self?.closed() }
                }
            )
            self.connection = connection
            connected = true
            appendNote("connected · \(baud) baud · 8N1")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disconnect() {
        connection?.close()
    }

    /// Sends one line (text mode: UTF-8 + line ending; hex mode: the typed
    /// hex bytes verbatim). Returns false when hex input does not parse.
    @discardableResult
    func send(_ input: String) -> Bool {
        guard let connection, connected else { return false }
        var data: Data
        if hexMode {
            guard let bytes = Format.parseHexBytes(input) else {
                error = "not valid hex — use pairs like \"0d 0a ff\""
                return false
            }
            data = bytes
        } else {
            data = Data(input.utf8)
            data.append(lineEnding.bytes)
        }
        error = nil
        connection.send(data)
        txBytes += data.count
        record(outgoing: true, data)
        return true
    }

    func clear() {
        text = ""
        hex = ""
        hexColumn = 0
    }

    /// Full timestamped transcript (both directions) as text: each entry
    /// carries direction, size, hex, and printable ASCII.
    func transcript() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# PorTree serial transcript — \(path) @ \(baud) baud 8N1"]
        for entry in log {
            let hexText = entry.data.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = String(entry.data.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append("\(formatter.string(from: entry.date)) \(entry.outgoing ? "TX" : "RX") \(entry.data.count) B  \(hexText)  |\(ascii)|")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "serial-\((path as NSString).lastPathComponent).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcript().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "could not save transcript: \(error.localizedDescription)"
        }
    }

    // MARK: Internals

    private func receive(_ data: Data) {
        rxBytes += data.count
        record(outgoing: false, data)
        text += String(decoding: data, as: UTF8.self)
        for byte in data {
            hex += String(format: "%02x", byte)
            hexColumn += 1
            hex += hexColumn % 16 == 0 ? "\n" : " "
        }
        if text.count > Self.outputCap { text = String(text.suffix(Self.outputCap)) }
        if hex.count > Self.outputCap { hex = String(hex.suffix(Self.outputCap)) }
    }

    private func closed() {
        if connected { appendNote("disconnected") }
        connected = false
        connection = nil
    }

    private func appendNote(_ note: String) {
        let line = "\n— \(note) —\n"
        text += line
        hex += line
        hexColumn = 0
    }

    private func record(outgoing: Bool, _ data: Data) {
        log.append(LogEntry(date: Date(), outgoing: outgoing, data: data))
        if log.count > Self.logCap { log.removeFirst(log.count - Self.logCap) }
    }
}

/// The serial console window: baud / line ending / hex controls, the live
/// output, and an input line.
struct SerialTerminalView: View {
    @State private var session: SerialSession
    @State private var input = ""

    init(path: String) {
        _session = State(initialValue: SerialSession(path: path))
    }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(session.connected ? .green : .secondary)
                Text(session.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("Baud", selection: $session.baud) {
                    ForEach(SerialSession.baudRates, id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 140)
                .disabled(session.connected)
                Picker("Send", selection: $session.lineEnding) {
                    ForEach(SerialSession.LineEnding.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 130)
                .disabled(session.hexMode)
                Toggle("Hex", isOn: $session.hexMode)
                    .toggleStyle(.checkbox)
                Button(session.connected ? "Disconnect" : "Connect") {
                    session.connected ? session.disconnect() : session.connect()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            .controlSize(.small)
            .padding(10)

            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.hexMode ? session.hex : session.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onChange(of: session.rxBytes) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack(spacing: 8) {
                TextField(session.hexMode ? "Hex bytes, e.g. 0d 0a ff" : "Type and press Return to send", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(sendInput)
                    .disabled(!session.connected)
                Button("Send", action: sendInput)
                    .disabled(!session.connected || input.isEmpty)
                Divider().frame(height: 16)
                Text("RX \(session.rxBytes) · TX \(session.txBytes)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear") { session.clear() }
                Button("Save Transcript…") { session.saveTranscript() }
            }
            .controlSize(.small)
            .padding(10)

            Text("Opening the port asserts DTR — many development boards reset when a console connects.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
        }
        .frame(minWidth: 640, minHeight: 380)
        .navigationTitle("Serial — \((session.path as NSString).lastPathComponent)")
        .onDisappear { session.disconnect() }
    }

    private func sendInput() {
        if session.send(input) { input = "" }
    }
}
