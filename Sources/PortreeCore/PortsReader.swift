import Foundation
import IOKit

/// One PD power level a source offers (Apple pre-decodes these into plain
/// mV/mA/mW inside IOPortFeaturePowerSource — no spec math involved).
public struct PDO: Sendable, Hashable, Codable {
    public let voltageMV: Int64
    public let maxCurrentMA: Int64
    public let maxPowerMW: Int64

    public var label: String {
        "\(Format.milli(voltageMV)) V · \(Format.milli(maxCurrentMA)) A · \(maxPowerMW / 1000) W"
    }
}

/// The cable eMarker's Discover Identity response (SOP' on the CC wire).
/// Raw VDOs are kept verbatim; decode happens through the USB-PD R3.x
/// tables (mirrored by Linux include/linux/usb/pd_vdo.h) — bit-level layout
/// verified live against macOS's own `Product Type Description`.
public struct EMarker: Sendable, Hashable, Codable {
    public let vendorID: Int64?
    public let productID: Int64?
    public let bcdDevice: Int64?
    /// macOS's own decode, verbatim ("Passive Cable" / "Active Cable").
    public let productTypeDescription: String?
    public let productTypeRaw: Int64?
    /// [ID Header, Cert Stat, Product VDO, Cable VDO1, (Active) VDO2] —
    /// little-endian UInt32 each.
    public let vdos: [Data]

    public init(vendorID: Int64?, productID: Int64?, bcdDevice: Int64?, productTypeDescription: String?, productTypeRaw: Int64?, vdos: [Data]) {
        self.vendorID = vendorID
        self.productID = productID
        self.bcdDevice = bcdDevice
        self.productTypeDescription = productTypeDescription
        self.productTypeRaw = productTypeRaw
        self.vdos = vdos
    }

    private func vdo(_ index: Int) -> UInt32? {
        guard vdos.count > index, vdos[index].count >= 4 else { return nil }
        let d = vdos[index]
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }  // little-endian on arm64/x86
    }

    public var isActiveCable: Bool { productTypeRaw == 4 }
    public var isPassiveCable: Bool { productTypeRaw == 3 }

    /// Cable VDO1's own version field (bits 23:21). PD 2.0-era eMarkers
    /// report 0 here and use a DIFFERENT layout for some fields — those
    /// fields stay silent rather than decode garbage.
    private var vdo1Version: UInt32? {
        vdo(3).map { ($0 >> 21) & 0x7 }
    }

    /// Cable VDO1 (index 3) — current/latency/termination bit positions are
    /// shared by PD 2.0 and R3.x layouts.
    public var ratedCurrent: String? {
        guard let v = vdo(3) else { return nil }
        switch (v >> 5) & 0x3 {
        case 1: return "3 A"
        case 2: return "5 A"
        default: return nil
        }
    }

    /// R3.x only: in PD 2.0 these bits mean SSTX directionality, so a
    /// version-0 VDO renders nothing instead of a fabricated voltage.
    public var maxVBusVoltage: String? {
        guard let v = vdo(3), let version = vdo1Version, version >= 1 else { return nil }
        return "\(20 + 10 * Int((v >> 9) & 0x3)) V"
    }

    public var ratedSpeed: String? {
        guard let v = vdo(3) else { return nil }
        let pd2 = (vdo1Version ?? 0) == 0
        switch v & 0x7 {
        case 0: return "USB 2.0 · 480 Mb/s"
        case 1: return "USB 3.2 Gen1 · 5 Gb/s"
        // PD 2.0's code 2 certifies Gen2 at 10 Gb/s; R3.x extends it to
        // USB4 Gen2 operation.
        case 2: return pd2 ? "USB 3.1 Gen2 · 10 Gb/s" : "USB 3.2/USB4 Gen2 · up to 20 Gb/s"
        case 3: return "USB4 Gen3 · 40 Gb/s"
        case 4: return "USB4 Gen4 · 80 Gb/s"
        default: return nil
        }
    }

    /// Latency class: code N spans ((N−1)·10, N·10] ns, code 1 is "<10 ns".
    /// Only a PASSIVE cable's latency maps honestly to a physical length —
    /// an active cable's figure includes retimer delay.
    public var latencyLabel: String? {
        guard let v = vdo(3) else { return nil }
        let code = Int((v >> 13) & 0xF)
        guard code > 0 else { return nil }
        let ns = code == 1 ? "<10 ns" : (code <= 7 ? "\((code - 1) * 10)–\(code * 10) ns" : ">70 ns")
        if isPassiveCable {
            return code <= 7 ? "\(ns) · ≈\(code) m class" : "\(ns) · >7 m class"
        }
        return "\(ns) latency class (includes retimer)"
    }

    public var termination: String? {
        guard let v = vdo(3) else { return nil }
        switch (v >> 11) & 0x3 {
        case 0: return "passive"
        case 1: return "passive · VCONN required"
        case 2: return "one end active"
        case 3: return "both ends active"
        default: return nil
        }
    }

    /// Active Cable VDO2 (index 4). The spec's support bits use 0 = yes.
    public var construction: String? {
        guard isActiveCable, let v = vdo(4) else { return nil }
        var parts: [String] = []
        parts.append((v >> 10) & 1 == 0 ? "copper" : "optical")
        parts.append((v >> 9) & 1 == 1 ? "retimer" : "redriver")
        if (v >> 8) & 1 == 0 { parts.append("USB4") }
        return parts.joined(separator: " · ")
    }
}

/// The far end of the CC wire (SOP): the port partner's PD identity.
public struct PortPartner: Sendable, Hashable, Codable {
    public let vendorID: Int64?
    public let productID: Int64?

    public init(vendorID: Int64?, productID: Int64?) {
        self.vendorID = vendorID
        self.productID = productID
    }
}

/// One physical receptacle (USB-C or MagSafe 3) with everything the port
/// manager proves about what's plugged into it: the cable's eMarker, the
/// PD partner, the first-hop TB/USB4 router UID (the graph join key), and
/// the PD power contract when this port powers the Mac.
public struct PortLink: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(portType)#\(portNumber)" }
    public let portType: String       // "USB-C" | "MagSafe 3"
    public let portNumber: Int64
    public let active: Bool
    public let partner: PortPartner?
    public let eMarker: EMarker?
    /// CIO child's UID == the first-hop IOThunderboltSwitch UID.
    public let cioUID: UInt64?
    public let cableGeneration: Int64?
    public let cableSpeed: Int64?
    /// PD contract when this port is POWERING the Mac.
    public let powerContract: PDO?

    public init(
        portType: String, portNumber: Int64, active: Bool,
        partner: PortPartner?, eMarker: EMarker?, cioUID: UInt64?,
        cableGeneration: Int64?, cableSpeed: Int64?,
        powerContract: PDO?
    ) {
        self.portType = portType
        self.portNumber = portNumber
        self.active = active
        self.partner = partner
        self.eMarker = eMarker
        self.cioUID = cioUID
        self.cableGeneration = cableGeneration
        self.cableSpeed = cableSpeed
        self.powerContract = powerContract
    }
}

public enum PortsReader {

    /// All physical receptacles from the USB-C port manager (AppleHPM) tree.
    /// Join key throughout: (port type description, built-in port number) —
    /// port numbers are namespaced per type (USB-C 1 and MagSafe 1 coexist).
    public static func enumerate() -> [PortLink] {
        // CIO (TB/USB4 fabric) state per receptacle.
        var cio: [String: (uid: UInt64?, generation: Int64?, speed: Int64?)] = [:]
        for service in Registry.matchingServices("IOPortTransportStateCIO") {
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let key = portKey(props) else { continue }
            cio[key] = (
                uid: props["UID"]?.intValue.map { UInt64(bitPattern: $0) },
                generation: props["CableGeneration"]?.intValue,
                speed: props["CableSpeed"]?.intValue
            )
        }

        // Incoming PD contract per receptacle: only the feature node that
        // carries a WinningPowerSourceOption is a source feeding the Mac
        // (its sibling is the Mac's own 5V offer going OUT). The sibling
        // PowerSourceOptions menu arrives as a description STRING through
        // CreateCFProperties, so the source's advertised menu is read from
        // AdapterDetails.UsbHvcMenu (PowerReader) instead — same data, typed.
        var power: [String: PDO] = [:]
        for service in Registry.matchingServices("IOPortFeaturePowerSource") {
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let key = portKey(props),
                  let winning = props["WinningPowerSourceOption"]?.dictValue,
                  let contract = pdo(from: winning) else { continue }
            power[key] = contract
        }

        // CC (PD identity) roots define the port list.
        return Registry.matchingServices("IOPortTransportStateCC").compactMap { service -> PortLink? in
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let number = props["ParentBuiltInPortNumber"]?.intValue else { return nil }
            let type = props["ParentBuiltInPortTypeDescription"]?.stringValue ?? "USB-C"
            let key = "\(type)#\(number)"

            var partner: PortPartner?
            var eMarker: EMarker?
            let children = Registry.children(of: service, plane: "IOService")
            defer { children.forEach { IOObjectRelease($0) } }
            for child in children {
                let childProps = Registry.properties(of: child)
                let metadata = childProps["Metadata"]?.dictValue ?? [:]
                switch childProps["AddressDescription"]?.stringValue {
                case "SOP":
                    partner = PortPartner(
                        vendorID: metadata["Vendor ID"]?.intValue,
                        productID: metadata["Product ID"]?.intValue
                    )
                case "SOP'":
                    eMarker = EMarker(
                        vendorID: metadata["Vendor ID"]?.intValue,
                        productID: metadata["Product ID"]?.intValue,
                        bcdDevice: metadata["bcdDevice"]?.intValue,
                        productTypeDescription: childProps["Product Type Description"]?.stringValue
                            ?? metadata["Product Type Description"]?.stringValue,
                        productTypeRaw: childProps["Product Type"]?.intValue
                            ?? metadata["Product Type"]?.intValue,
                        vdos: (metadata["VDOs"]?.arrayValue ?? []).compactMap(\.dataValue)
                    )
                default:
                    break
                }
            }

            return PortLink(
                portType: type,
                portNumber: number,
                active: props["Active"]?.boolValue ?? false,
                partner: partner,
                eMarker: eMarker,
                cioUID: cio[key]?.uid,
                cableGeneration: cio[key]?.generation,
                cableSpeed: cio[key]?.speed,
                powerContract: power[key]
            )
        }
        .sorted { ($0.portType, $0.portNumber) < ($1.portType, $1.portNumber) }
    }

    private static func portKey(_ props: [String: PropertyValue]) -> String? {
        guard let number = props["ParentBuiltInPortNumber"]?.intValue else { return nil }
        let type = props["ParentBuiltInPortTypeDescription"]?.stringValue ?? "USB-C"
        return "\(type)#\(number)"
    }

    private static func pdo(from dict: [String: PropertyValue]) -> PDO? {
        guard let voltage = dict["Voltage (mV)"]?.intValue else { return nil }
        return PDO(
            voltageMV: voltage,
            maxCurrentMA: dict["Max Current (mA)"]?.intValue ?? 0,
            maxPowerMW: dict["Max Power (mW)"]?.intValue ?? 0
        )
    }
}

extension Format {
    /// "20000 mV" → "20", "4500 mA" → "4.5" — trims trailing .0.
    public static func milli(_ value: Int64) -> String {
        value % 1000 == 0 ? "\(value / 1000)" : String(format: "%.1f", Double(value) / 1000)
    }
}
