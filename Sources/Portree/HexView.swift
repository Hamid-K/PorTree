import SwiftUI

/// Classic hex dump sheet for OSData registry blobs (UsbDeviceSignature,
/// DROM, EDID…): offset · hex · ASCII, 16 bytes per row.
struct HexView: View {
    @Environment(\.dismiss) private var dismiss
    let payload: HexPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(payload.key).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("\(payload.data.count) bytes").foregroundStyle(.secondary).font(.system(size: 11))
                Spacer()
                Button("Copy hex") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        payload.data.map { String(format: "%02x", $0) }.joined(separator: " "),
                        forType: .string
                    )
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(dump)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 320)
    }

    private var dump: String {
        var lines: [String] = []
        let bytes = [UInt8](payload.data)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.enumerated()
                .map { index, byte in String(format: "%02x", byte) + (index == 7 ? " " : "") }
                .joined(separator: " ")
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "·" }.joined()
            lines.append(String(format: "%08x  %-49s  %@", offset, hex.padding(toLength: 49, withPad: " ", startingAt: 0), ascii))
        }
        return lines.joined(separator: "\n")
    }
}
