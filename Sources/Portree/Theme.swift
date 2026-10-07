import SwiftUI
import PortreeCore

/// Color = protocol/speed tier; icon = device class — two orthogonal facts.
/// System colors adapt to dark/light automatically. Color never stands alone:
/// the speed text is always rendered next to it.
extension Tier {
    var color: Color {
        switch self {
        case .usb1: return .gray
        case .usb2: return .orange
        case .usb3: return .blue
        case .usb4: return .purple
        case .thunderbolt: return .indigo
        case .fabric: return .cyan
        case .infrastructure: return Color.secondary.opacity(0.9)
        case .error: return .red
        }
    }

    var legendLabel: String {
        switch self {
        case .usb1: return "USB 1.x · 1.5–12 Mb/s"
        case .usb2: return "USB 2.0 · 480 Mb/s"
        case .usb3: return "USB 3.x · 5–20 Gb/s"
        case .usb4: return "USB4 · tunneled 40 Gb/s+"
        case .thunderbolt: return "Thunderbolt / USB4 fabric"
        case .fabric: return "Apple Fabric · SoC interconnect"
        case .infrastructure: return "Infrastructure (controllers, idle)"
        case .error: return "Error / removed"
        }
    }
}

extension DeviceCategory {
    var symbol: String {
        switch self {
        case .controller: return "cpu"
        case .hub: return "cable.connector.horizontal"
        case .hid: return "keyboard"
        case .mouse: return "computermouse"
        case .storage: return "externaldrive"
        case .audio: return "mic"
        case .speaker: return "hifispeaker"
        case .video: return "camera"
        case .network: return "network"
        case .display: return "display"
        case .printer: return "printer"
        case .smartCard: return "creditcard"
        case .wireless: return "dot.radiowaves.left.and.right"
        case .tbSwitch: return "bolt.horizontal"
        case .tbDomain: return "bolt.horizontal.circle"
        case .adapter: return "cable.connector"
        case .vendor: return "shippingbox"
        case .unknown: return "questionmark.square.dashed"
        case .pci: return "memorychip"
        case .system: return "laptopcomputer"
        }
    }
}

/// Graph canvas background — selectable because "gray line on gray canvas"
/// is unreadable; each option carries a matching opaque chip fill for edge
/// labels so text always sits on contrast.
enum CanvasBackground: String, CaseIterable {
    case system, graphite, light

    var label: String {
        switch self {
        case .system: return "System"
        case .graphite: return "Graphite"
        case .light: return "Light"
        }
    }

    var color: Color {
        switch self {
        case .system: return Color(nsColor: .underPageBackgroundColor)
        case .graphite: return Color(red: 0.085, green: 0.09, blue: 0.11)
        case .light: return Color(white: 0.96)
        }
    }

    var chipFill: Color {
        switch self {
        case .system: return Color(nsColor: .controlBackgroundColor)
        case .graphite: return Color(red: 0.16, green: 0.17, blue: 0.20)
        case .light: return .white
        }
    }

    /// Readable label-text color on this background for low-contrast tiers.
    var mutedText: Color {
        self == .light ? Color(white: 0.25) : Color(white: 0.78)
    }
}

enum Theme {
    /// Edge stroke width by negotiated speed — thickness is the second visual
    /// speed encoding after color.
    static func edgeWidth(bps: Int64) -> CGFloat {
        switch bps {
        case ..<1: return 1.2
        case ..<13_000_000: return 1.2
        case ..<1_000_000_000: return 2.0
        case ..<6_000_000_000: return 2.8
        case ..<11_000_000_000: return 3.4
        case ..<21_000_000_000: return 4.0
        case ..<41_000_000_000: return 5.0
        default: return 6.0
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Protocol-stack badge for top-level sections (corner chip + backbone
    /// edge color): USB blue, Thunderbolt indigo, PCIe teal, Apple Fabric cyan.
    static func protocolBadge(for node: PortreeCore.DeviceNode) -> (label: String, color: Color)? {
        if node.tier == .fabric { return ("Fabric", .cyan) }
        switch node.kind {
        case .usbController: return ("USB", .blue)
        case .tbDomain: return ("TB/USB4", .indigo)
        case .pciDevice: return ("PCIe", .teal)
        default: return nil
        }
    }

    /// Live throughput label (bytes/sec, binary-ish steps kept human).
    static func rate(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case ..<1_000: return String(format: "%.0f B/s", bytesPerSec)
        case ..<1_000_000: return String(format: "%.1f KB/s", bytesPerSec / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f MB/s", bytesPerSec / 1_000_000)
        default: return String(format: "%.2f GB/s", bytesPerSec / 1_000_000_000)
        }
    }
}
