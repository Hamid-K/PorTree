import Foundation

/// Protocol/speed tier used for color coding. Edge/border color derives from
/// this; the speed text itself is always shown too (never color alone).
public enum Tier: String, Sendable, Codable, Hashable {
    case usb1, usb2, usb3, usb4, thunderbolt, fabric, infrastructure, error
}

public enum Format {

    /// Human label for a link speed in bits/s. All Int64 formatting in this app
    /// goes through interpolation — `String(format: "%d", int64)` silently
    /// truncates to 32 bits (10 Gb/s became 1.4 Gb/s in testing).
    public static func speedLabel(bps: Int64) -> String {
        guard bps > 0 else { return "" }
        if bps % 1_000_000_000 == 0 { return "\(bps / 1_000_000_000) Gb/s" }
        if bps >= 1_000_000_000 {
            let tenths = bps / 100_000_000
            return "\(tenths / 10).\(tenths % 10) Gb/s"
        }
        if bps % 1_000_000 == 0 { return "\(bps / 1_000_000) Mb/s" }
        let tenths = bps / 100_000
        return "\(tenths / 10).\(tenths % 10) Mb/s"
    }

    public static func tier(forBps bps: Int64) -> Tier {
        switch bps {
        case ..<1: return .infrastructure
        case ..<13_000_000: return .usb1          // 1.5 / 12 M
        case ..<1_000_000_000: return .usb2       // 480 M
        case ..<21_000_000_000: return .usb3      // 5 / 10 / 20 G
        default: return .usb4                      // tunneled 40 G+
        }
    }

    /// tIOUSBHostConnectionSpeed — note Full/Low are SWAPPED vs the legacy
    /// `Device Speed` enum (legacy: 0 Low, 1 Full, 2 High, 3 Super, 4 Super+).
    public static func usbSpeedEnumLabel(_ v: Int64) -> String {
        switch v {
        case 0: return "None"
        case 1: return "Full (12 Mb/s)"
        case 2: return "Low (1.5 Mb/s)"
        case 3: return "High (480 Mb/s)"
        case 4: return "SuperSpeed (5 Gb/s)"
        case 5: return "SuperSpeed+ (10 Gb/s)"
        case 6: return "SuperSpeed+ (20 Gb/s)"
        default: return "Other (\(v))"
        }
    }

    public static func usbClassName(_ code: Int64) -> String {
        switch code {
        case 0x00: return "Composite (class at interface)"
        case 0x01: return "Audio"
        case 0x02: return "CDC Control"
        case 0x03: return "HID"
        case 0x05: return "Physical"
        case 0x06: return "Still Image / PTP"
        case 0x07: return "Printer"
        case 0x08: return "Mass Storage"
        case 0x09: return "Hub"
        case 0x0A: return "CDC Data"
        case 0x0B: return "Smart Card"
        case 0x0D: return "Content Security"
        case 0x0E: return "Video (UVC)"
        case 0x0F: return "Personal Healthcare"
        case 0x10: return "Audio/Video"
        case 0x11: return "Billboard"
        case 0x12: return "USB-C Bridge"
        case 0xDC: return "Diagnostic"
        case 0xE0: return "Wireless"
        case 0xEF: return "Miscellaneous"
        case 0xFE: return "Application-specific"
        case 0xFF: return "Vendor-specific"
        default: return "0x" + String(code, radix: 16, uppercase: true)
        }
    }

    public static func usbPortTypeLabel(_ v: Int64) -> String {
        switch v {
        case 0: return "Standard"
        case 1: return "Captive"
        case 2: return "Internal"
        case 3: return "Accessory"
        case 4: return "ExpressCard"
        case 5: return "USB-C"
        default: return "\(v)"
        }
    }

    /// locationID = 0xBBPPPPPP: top byte = bus, one nibble per hub tier below.
    /// Display only — topology always comes from registry parent chains
    /// (a nibble cannot express ports > 15).
    public static func locationPath(_ locationID: Int64) -> String {
        let loc = UInt32(truncatingIfNeeded: locationID)
        let bus = loc >> 24
        var ports: [String] = []
        var shift = 20
        while shift >= 0 {
            let nibble = (loc >> UInt32(shift)) & 0xF
            if nibble == 0 { break }
            ports.append("\(nibble)")
            shift -= 4
        }
        let path = ports.isEmpty ? "root" : ports.joined(separator: ".")
        return "bus \(bus) · \(path)"
    }

    public static func hex(_ v: Int64, width: Int = 0) -> String {
        let s = String(UInt64(bitPattern: v), radix: 16, uppercase: true)
        let padded = width > s.count ? String(repeating: "0", count: width - s.count) + s : s
        return "0x" + padded
    }

    /// Thunderbolt switch UIDs arrive as *signed* CFNumbers; the identity is
    /// the bit pattern (Dell −9185171858847104256 == 0x8087B6DC08810300).
    public static func tbUID(_ signed: Int64) -> String {
        hex(signed, width: 16)
    }

    /// NVM firmware = hex(ROM Version) "." EEPROM Revision — (68, 3) → "44.3".
    public static func nvmVersion(rom: Int64, eeprom: Int64) -> String {
        String(rom, radix: 16) + ".\(eeprom)"
    }

    /// BCD like 0x0320 → "3.20".
    public static func bcd(_ v: Int64) -> String {
        String(format: "%x.%02x", Int(v >> 8) & 0xFF, Int(v) & 0xFF)
    }

    /// Thunderbolt lane-port `Link Bandwidth` is in units of 0.1 Gb/s
    /// (400 = 40 Gb/s active, 1200 = TB5 capability).
    public static func tbLinkBandwidthLabel(tenthsGbps: Int64) -> String {
        if tenthsGbps % 10 == 0 { return "\(tenthsGbps / 10) Gb/s" }
        return "\(tenthsGbps / 10).\(tenthsGbps % 10) Gb/s"
    }

    public static func milliamps(_ v: Int64) -> String { "\(v) mA" }
}
