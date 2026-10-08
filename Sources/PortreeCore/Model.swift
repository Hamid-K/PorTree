import Foundation

public enum NodeKind: String, Sendable, Codable, Hashable {
    case usbController, usbDevice, tbDomain, tbSwitch, pciDevice, system
    /// A physical monitor as the port-transport subsystem records it
    /// (IOPortTransportStateDisplayPort) — a registry-real entry for a
    /// display that is electrically invisible to the USB/TB topology,
    /// e.g. a plain-DP monitor behind a TB→DP adapter.
    case displaySink
}

/// Device family driving the icon; orthogonal to `Tier` (color).
public enum DeviceCategory: String, Sendable, Codable, Hashable {
    case controller, hub, dock, hid, mouse, storage, audio, speaker, video, network, display
    case printer, smartCard, wireless, tbSwitch, tbDomain, adapter, vendor, unknown, pci, system
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

    /// HID boot-keyboard interface (class 3, subclass 1, protocol 1) — the
    /// signature a keystroke-injection device must expose to type.
    public var hasKeyboardInterface: Bool {
        interfaces.contains {
            $0.properties["bInterfaceClass"]?.intValue == 3
                && $0.properties["bInterfaceSubClass"]?.intValue == 1
                && $0.properties["bInterfaceProtocol"]?.intValue == 1
        }
    }

    public var hasStorageInterface: Bool {
        interfaces.contains { $0.properties["bInterfaceClass"]?.intValue == 0x08 }
    }

    public var hasVendorInterface: Bool {
        interfaces.contains { $0.properties["bInterfaceClass"]?.intValue == 0xFF }
    }

    /// Canonical copyable ID: USB vid:pid, PCI vendor:device (both hex), or
    /// the TB switch UID. Nil when the node carries no stable hardware ID.
    public var idPairLabel: String? {
        if let vid = vendorID, let pid = productID {
            return "\(Format.hex(vid, width: 4)):\(Format.hex(pid, width: 4))"
        }
        if kind == .tbSwitch, let uid = properties["UID"]?.intValue {
            return Format.tbUID(uid)
        }
        // PCI vendor-id / device-id: 4-byte little-endian Data (or plain
        // numbers); only the low 16 bits are the ID.
        func word(_ value: PropertyValue?) -> Int64? {
            switch value {
            case .int(let i): return i & 0xFFFF
            case .data(let d) where d.count >= 2:
                return Int64(d[d.startIndex]) | Int64(d[d.startIndex + 1]) << 8
            default: return nil
            }
        }
        if kind == .pciDevice,
           let vid = word(properties["vendor-id"]), let pid = word(properties["device-id"]) {
            return "\(Format.hex(vid, width: 4)):\(Format.hex(pid, width: 4))"
        }
        return nil
    }

    /// Carrying video: a TB switch with active DP adapters (reserved fabric
    /// bandwidth), a USB-graphics device (video over plain USB data — the
    /// opposite trade-off, worth telling apart), or a display sink itself.
    public var videoTunnelCount: Int64 { properties["Portree DPTunnels"]?.intValue ?? 0 }
    public var isDisplayLink: Bool { vendorID == 0x17E9 }
    public var carriesVideo: Bool { videoTunnelCount > 0 || usbGraphicsVendor != nil || kind == .displaySink }

    /// Video-over-USB graphics adapters (compressed, driver-rendered).
    /// DisplayLink's VID is dedicated to graphics, so it is provable from
    /// the VID alone. SMI (0x090C) and MCT (0x0711) share their VIDs with
    /// flash controllers and ship virtual-CD storage functions on the real
    /// adapters, so no interface-shape gate separates them reliably — they
    /// are deliberately NOT matched (no guessed labels).
    public var usbGraphicsVendor: String? {
        vendorID == 0x17E9 ? "DisplayLink" : nil
    }

    /// USB billboard device (class 0x11): a USB-C alt-mode adapter
    /// announcing itself. Per the Type-C spec a billboard that appears
    /// usually means alt-mode entry FAILED (the "plugged in, no picture"
    /// case) — though some adapters expose one on success too.
    public var isBillboard: Bool {
        deviceClassCode == 0x11
            || interfaces.contains { $0.properties["bInterfaceClass"]?.intValue == 0x11 }
    }

    /// Display-output occupancy on TB adapters/docks ("DP out 1/2").
    public var dpOutTotal: Int64? { properties["Portree DPOut Total"]?.intValue }
    public var dpOutUsed: Int64? { properties["Portree DPOut Used"]?.intValue }

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
    public let pciRoots: [DeviceNode]
    public let systemNode: DeviceNode?
    /// Physical monitors as the port-transport subsystem records them —
    /// captured here (on the IOKit queue) so the UI never touches IOKit.
    public let displaySinks: [DisplaySink]
    /// Physical receptacles with cable eMarker + PD contract facts.
    public let portLinks: [PortLink]
    /// The Mac's power-input state (adapter contract, live input watts).
    public let power: PowerInfo?
    public let takenAt: Date

    public init(
        usbRoots: [DeviceNode],
        tbRoots: [DeviceNode],
        pciRoots: [DeviceNode] = [],
        systemNode: DeviceNode? = nil,
        displaySinks: [DisplaySink] = [],
        portLinks: [PortLink] = [],
        power: PowerInfo? = nil,
        takenAt: Date = Date()
    ) {
        self.usbRoots = usbRoots
        self.tbRoots = tbRoots
        self.pciRoots = pciRoots
        self.systemNode = systemNode
        self.displaySinks = displaySinks
        self.portLinks = portLinks
        self.power = power
        self.takenAt = takenAt
    }

    // Hand-written decoding: baselines saved by older versions have no
    // displaySinks key and must keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usbRoots = try container.decode([DeviceNode].self, forKey: .usbRoots)
        tbRoots = try container.decode([DeviceNode].self, forKey: .tbRoots)
        pciRoots = try container.decodeIfPresent([DeviceNode].self, forKey: .pciRoots) ?? []
        systemNode = try container.decodeIfPresent(DeviceNode.self, forKey: .systemNode)
        displaySinks = try container.decodeIfPresent([DisplaySink].self, forKey: .displaySinks) ?? []
        portLinks = try container.decodeIfPresent([PortLink].self, forKey: .portLinks) ?? []
        power = try container.decodeIfPresent(PowerInfo.self, forKey: .power)
        takenAt = try container.decodeIfPresent(Date.self, forKey: .takenAt) ?? Date()
    }

    public var allRoots: [DeviceNode] {
        (systemNode.map { [$0] } ?? []) + usbRoots + tbRoots + pciRoots
    }

    /// The one way to take a full snapshot — GUI rescans and `--dump` must
    /// never diverge on what they capture. The System node is enriched with
    /// MEASURED host capabilities (registry truth: TB generation, per-port
    /// bandwidth, port counts, USB controller revisions, live DP tunnels) —
    /// never invented spec numbers.
    public static func capture() -> Snapshot {
        let usbRoots = USBTopologyBuilder.build()
        let tbRoots = TBTopologyBuilder.build()
        var system = SystemInfo.node()
        var props = system.properties

        // Thunderbolt: generation from the host switches' Thunderbolt Version
        // (64 = USB4 v2 host → TB5-class, 32 = USB4/TB4, 2 = TB3), bandwidth
        // from the best receptacle capability, port count from the domains.
        let hostSwitches = tbRoots.flatMap { $0.flattened() }
            .filter { $0.kind == .tbSwitch && $0.properties["Depth"]?.intValue == 0 }
        let tbVersion = hostSwitches.compactMap { $0.properties["Thunderbolt Version"]?.intValue }.max() ?? 0
        let tbGeneration: String? = tbVersion >= 64 ? "Thunderbolt 5 / USB4 v2"
            : tbVersion >= 32 ? "Thunderbolt 4 / USB4"
            : tbVersion > 0 ? "Thunderbolt 3" : nil
        let capability = tbRoots.map(\.speedLabel).filter { !$0.isEmpty }.max()
        if let tbGeneration {
            var parts = [tbGeneration]
            if let capability { parts.append("\(capability) per port") }
            parts.append("\(tbRoots.count) port\(tbRoots.count == 1 ? "" : "s")")
            props["Measured: Thunderbolt"] = .string(parts.joined(separator: " · "))
        }

        // USB: controller count and best protocol revision.
        let usbRevisions = usbRoots.compactMap { $0.properties["UsbHostControllerProtocolRevision"]?.stringValue }
        if !usbRoots.isEmpty {
            let revision = usbRevisions.max().map { "USB \($0)" } ?? "XHCI"
            props["Measured: USB"] = .string("\(usbRoots.count) controllers · \(revision)")
        }

        // DisplayPort: tunnels active right now (max supported displays is a
        // chip spec macOS does not publish — see Spec rows when known).
        let dpTunnels = tbRoots.flatMap { $0.flattened() }.map(\.videoTunnelCount).reduce(0, +)
        props["Measured: DisplayPort"] = .string(
            dpTunnels > 0 ? "\(dpTunnels) tunnel\(dpTunnels == 1 ? "" : "s") active now" : "no tunnels active now"
        )

        system = DeviceNode(
            id: system.id, kind: system.kind, name: system.name, subtitle: system.subtitle,
            className: system.className, category: system.category, tier: system.tier,
            speedLabel: system.speedLabel, linkSpeedBps: system.linkSpeedBps,
            properties: props
        )
        return Snapshot(
            usbRoots: usbRoots,
            tbRoots: tbRoots,
            pciRoots: PCITopologyBuilder.build(tbRoots: tbRoots),
            systemNode: system,
            displaySinks: DisplaySinks.enumerate(),
            portLinks: PortsReader.enumerate(),
            power: PowerReader.read()
        )
    }

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
