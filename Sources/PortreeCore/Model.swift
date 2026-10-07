import Foundation

public enum NodeKind: String, Sendable, Codable, Hashable {
    case usbController, usbDevice, tbDomain, tbSwitch
}

/// Broad device category driving the icon; orthogonal to `Tier` (color).
public enum DeviceCategory: String, Sendable, Codable, Hashable {
    case controller, hub, hid, storage, audio, video, network, display
    case tbSwitch, tbDomain, adapter, vendor, unknown
}

/// A secondary detail row under a node: a USB interface, or a Thunderbolt
/// adapter port. Shown in the inspector, never in the graph.
public struct SubEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var properties: [String: PropertyValue]

    public init(id: String, title: String, detail: String, properties: [String: PropertyValue] = [:]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.properties = properties
    }
}

/// Info about a merged USB2/USB3 hub twin (one physical hub, two logical
/// personalities paired by kUSBContainerID). The USB3 personality's registry
/// entry ID is canonical; the USB2 twin lives on as `secondaryID`.
public struct TwinInfo: Sendable, Hashable, Codable {
    public let secondaryID: UInt64
    public let secondaryName: String
    public let lowSpeedBps: Int64
    public let highSpeedBps: Int64

    public init(secondaryID: UInt64, secondaryName: String, lowSpeedBps: Int64, highSpeedBps: Int64) {
        self.secondaryID = secondaryID
        self.secondaryName = secondaryName
        self.lowSpeedBps = lowSpeedBps
        self.highSpeedBps = highSpeedBps
    }
}

public struct DeviceNode: Sendable, Hashable, Codable, Identifiable {
    /// IORegistry entry ID — stable for the life of the registry entry,
    /// changes on replug (sessionID changes too).
    public let id: UInt64
    public let kind: NodeKind
    /// Display name after the fallback chain (never empty).
    public let name: String
    /// Secondary line: vendor, controller class, etc.
    public let subtitle: String
    public let className: String
    public let category: DeviceCategory
    public let tier: Tier
    /// Human speed text, always displayed next to any color coding.
    public let speedLabel: String
    /// Negotiated link speed in bits/s when known (UsbLinkSpeed, or TB
    /// Link Bandwidth × 0.1 Gb/s), 0 otherwise. Drives edge thickness.
    public let linkSpeedBps: Int64
    public let properties: [String: PropertyValue]
    public var interfaces: [SubEntry]
    public var children: [DeviceNode]
    public var twin: TwinInfo?
    /// Registry entry ID of the counterpart in the other section
    /// (TB switch ↔ USB subtree), when deterministically known.
    public var crossLinkID: UInt64?

    public init(
        id: UInt64, kind: NodeKind, name: String, subtitle: String, className: String,
        category: DeviceCategory, tier: Tier, speedLabel: String, linkSpeedBps: Int64,
        properties: [String: PropertyValue], interfaces: [SubEntry] = [],
        children: [DeviceNode] = [], twin: TwinInfo? = nil, crossLinkID: UInt64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.subtitle = subtitle
        self.className = className
        self.category = category
        self.tier = tier
        self.speedLabel = speedLabel
        self.linkSpeedBps = linkSpeedBps
        self.properties = properties
        self.interfaces = interfaces
        self.children = children
        self.twin = twin
        self.crossLinkID = crossLinkID
    }
}

extension DeviceNode {
    public var vendorID: Int64? { properties["idVendor"]?.intValue }
    public var productID: Int64? { properties["idProduct"]?.intValue }
    public var serialNumber: String? { properties["USB Serial Number"]?.stringValue }
    public var isTunneled: Bool { properties["UsbTunnel"]?.boolValue == true }
    public var exclusiveOwner: String? { properties["UsbExclusiveOwner"]?.stringValue }
    public var powerSinkMA: Int64? { properties["UsbPowerSinkAllocation"]?.intValue }
    public var locationID: Int64? { properties["locationID"]?.intValue }
    public var deviceClassCode: Int64? { properties["bDeviceClass"]?.intValue }
    public var isHub: Bool { deviceClassCode == 9 }

    public var containerIDKey: String? {
        guard let v = properties["kUSBContainerID"] else { return nil }
        switch v {
        case .string(let s): return s
        case .data(let d): return d.map { String(format: "%02x", $0) }.joined()
        default: return nil
        }
    }

    /// Two-level identity for replug matching and history:
    /// VID+PID+serial when a serial exists, else VID+PID+location path
    /// (marked low-confidence by callers — a serial-less device that moves
    /// ports must not be treated as a brand-new device with certainty).
    public var deviceIdentity: (key: String, confident: Bool)? {
        guard let vid = vendorID, let pid = productID else {
            if kind == .tbSwitch, let uid = properties["UID"]?.intValue {
                return ("tb:\(Format.tbUID(uid))", true)
            }
            return nil
        }
        if let serial = serialNumber, !serial.isEmpty {
            return ("usb:\(vid):\(pid):\(serial)", true)
        }
        let loc = locationID.map { Format.locationPath($0) } ?? "?"
        return ("usb:\(vid):\(pid)@\(loc)", false)
    }

    /// Depth-first flatten of this subtree (self included).
    public func flattened() -> [DeviceNode] {
        [self] + children.flatMap { $0.flattened() }
    }
}

public struct Snapshot: Sendable, Codable {
    public let usbRoots: [DeviceNode]
    public let tbRoots: [DeviceNode]
    public let takenAt: Date

    public init(usbRoots: [DeviceNode], tbRoots: [DeviceNode], takenAt: Date = Date()) {
        self.usbRoots = usbRoots
        self.tbRoots = tbRoots
        self.takenAt = takenAt
    }

    public var allRoots: [DeviceNode] { usbRoots + tbRoots }

    public func allByID() -> [UInt64: DeviceNode] {
        var out: [UInt64: DeviceNode] = [:]
        for root in allRoots {
            for node in root.flattened() { out[node.id] = node }
        }
        return out
    }

    /// Count of actual devices (excludes controllers/domains).
    public var deviceCount: Int {
        allRoots.flatMap { $0.flattened() }.filter { $0.kind == .usbDevice || $0.kind == .tbSwitch }.count
    }
}
