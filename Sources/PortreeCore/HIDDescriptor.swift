import Foundation

/// Decoder for HID report descriptors (HID 1.11 §6.2.2 item format). Purely
/// descriptive: it parses the registry's copy of the descriptor, never the
/// device. Output is an indented item listing plus a per-report size summary.
public struct HIDDescriptor {

    public struct Line: Sendable, Hashable {
        public let depth: Int
        public let text: String
    }

    /// Per report ID: total bits for each main item kind.
    public struct ReportSummary: Sendable, Hashable {
        public let reportID: Int
        public let inputBits: Int
        public let outputBits: Int
        public let featureBits: Int
    }

    public let lines: [Line]
    public let reports: [ReportSummary]
    /// True when every top-level usage page is vendor-defined.
    public let vendorDefined: Bool

    public init(_ data: Data) {
        var lines: [Line] = []
        var depth = 0
        var usagePage: UInt32 = 0
        var reportSize = 0
        var reportCount = 0
        var reportID = 0
        var globalStack: [(UInt32, Int, Int, Int)] = []
        var totals: [Int: (input: Int, output: Int, feature: Int)] = [:]
        var topPages: [UInt32] = []

        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            // Long item: 0xFE, size, tag, data — skipped, never used in practice.
            if prefix == 0xFE {
                let size = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0
                lines.append(Line(depth: depth, text: "Long item (\(size) B)"))
                i += 3 + size
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            let type = (prefix >> 2) & 0x03
            let tag = (prefix >> 4) & 0x0F
            guard i + size < bytes.count || size == 0 else {
                lines.append(Line(depth: depth, text: "⚠︎ truncated item at byte \(i)"))
                break
            }
            var value: UInt32 = 0
            for b in 0..<size { value |= UInt32(bytes[i + 1 + b]) << (8 * b) }
            let signed: Int32 = {
                switch size {
                case 1: return Int32(Int8(bitPattern: UInt8(value & 0xFF)))
                case 2: return Int32(Int16(bitPattern: UInt16(value & 0xFFFF)))
                case 4: return Int32(bitPattern: value)
                default: return 0
                }
            }()
            i += 1 + size

            switch (type, tag) {
            // Main items
            case (0, 0x8), (0, 0x9), (0, 0xB):
                let kind = tag == 0x8 ? "Input" : (tag == 0x9 ? "Output" : "Feature")
                let flags = [
                    value & 0x01 == 0 ? "Data" : "Const",
                    value & 0x02 == 0 ? "Array" : "Var",
                    value & 0x04 == 0 ? "Abs" : "Rel",
                ].joined(separator: ",")
                let bits = reportSize * reportCount
                lines.append(Line(depth: depth, text: "\(kind) (\(flags)) — \(reportCount) × \(reportSize) bit = \(bits) bit"))
                var entry = totals[reportID] ?? (0, 0, 0)
                switch tag {
                case 0x8: entry.input += bits
                case 0x9: entry.output += bits
                default: entry.feature += bits
                }
                totals[reportID] = entry
            case (0, 0xA):
                let kinds = ["Physical", "Application", "Logical", "Report", "Named Array", "Usage Switch", "Usage Modifier"]
                let name = Int(value) < kinds.count ? kinds[Int(value)] : String(format: "0x%02X", value)
                lines.append(Line(depth: depth, text: "Collection (\(name))"))
                if depth == 0 { topPages.append(usagePage) }
                depth += 1
            case (0, 0xC):
                depth = max(0, depth - 1)
                lines.append(Line(depth: depth, text: "End Collection"))
            // Global items
            case (1, 0x0):
                usagePage = value
                lines.append(Line(depth: depth, text: "Usage Page (\(Self.pageName(value)))"))
            case (1, 0x1): lines.append(Line(depth: depth, text: "Logical Minimum (\(signed))"))
            case (1, 0x2): lines.append(Line(depth: depth, text: "Logical Maximum (\(signed))"))
            case (1, 0x3): lines.append(Line(depth: depth, text: "Physical Minimum (\(signed))"))
            case (1, 0x4): lines.append(Line(depth: depth, text: "Physical Maximum (\(signed))"))
            case (1, 0x5): lines.append(Line(depth: depth, text: "Unit Exponent (\(signed))"))
            case (1, 0x6): lines.append(Line(depth: depth, text: String(format: "Unit (0x%X)", value)))
            case (1, 0x7):
                reportSize = Int(value)
                lines.append(Line(depth: depth, text: "Report Size (\(value))"))
            case (1, 0x8):
                reportID = Int(value)
                lines.append(Line(depth: depth, text: String(format: "Report ID (0x%02X)", value)))
            case (1, 0x9):
                reportCount = Int(value)
                lines.append(Line(depth: depth, text: "Report Count (\(value))"))
            case (1, 0xA):
                globalStack.append((usagePage, reportSize, reportCount, reportID))
                lines.append(Line(depth: depth, text: "Push"))
            case (1, 0xB):
                if let state = globalStack.popLast() {
                    (usagePage, reportSize, reportCount, reportID) = state
                }
                lines.append(Line(depth: depth, text: "Pop"))
            // Local items
            case (2, 0x0):
                lines.append(Line(depth: depth, text: "Usage (\(Self.usageName(page: usagePage, usage: value)))"))
            case (2, 0x1): lines.append(Line(depth: depth, text: String(format: "Usage Minimum (0x%X)", value)))
            case (2, 0x2): lines.append(Line(depth: depth, text: String(format: "Usage Maximum (0x%X)", value)))
            case (2, 0x7): lines.append(Line(depth: depth, text: "String Index (\(value))"))
            default:
                lines.append(Line(depth: depth, text: String(format: "Item type %d tag 0x%X (0x%X)", type, tag, value)))
            }
        }

        self.lines = lines
        self.reports = totals.keys.sorted().map { id in
            let t = totals[id]!
            return ReportSummary(reportID: id, inputBits: t.input, outputBits: t.output, featureBits: t.feature)
        }
        self.vendorDefined = !topPages.isEmpty && topPages.allSatisfy { $0 == 0xFF || $0 >= 0xFF00 }
    }

    public static func pageName(_ page: UInt32) -> String {
        switch page {
        case 0x01: return "Generic Desktop"
        case 0x06: return "Generic Device Controls"
        case 0x07: return "Keyboard/Keypad"
        case 0x08: return "LED"
        case 0x09: return "Button"
        case 0x0C: return "Consumer"
        case 0x0D: return "Digitizer"
        case 0x0F: return "Physical Interface Device"
        case 0x14: return "Alphanumeric Display"
        case 0x20: return "Sensors"
        case 0x84: return "Power Device"
        case 0x85: return "Battery System"
        case 0xFF, 0xFF00...0xFFFF: return String(format: "Vendor-defined 0x%X", page)
        default: return String(format: "0x%02X", page)
        }
    }

    public static func usageName(page: UInt32, usage: UInt32) -> String {
        switch (page, usage) {
        case (0x01, 0x01): return "Pointer"
        case (0x01, 0x02): return "Mouse"
        case (0x01, 0x04): return "Joystick"
        case (0x01, 0x05): return "Gamepad"
        case (0x01, 0x06): return "Keyboard"
        case (0x01, 0x07): return "Keypad"
        case (0x01, 0x30): return "X"
        case (0x01, 0x31): return "Y"
        case (0x01, 0x32): return "Z"
        case (0x01, 0x38): return "Wheel"
        case (0x01, 0x80): return "System Control"
        case (0x0C, 0x01): return "Consumer Control"
        case (0x0C, 0xCD): return "Play/Pause"
        case (0x0C, 0xE2): return "Mute"
        case (0x0C, 0xE9): return "Volume Up"
        case (0x0C, 0xEA): return "Volume Down"
        case (0x0D, 0x05): return "Touch Pad"
        default: return String(format: "0x%X", usage)
        }
    }
}
