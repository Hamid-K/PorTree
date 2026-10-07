import Foundation
import IOKit

/// Builds the USB tree by walking the IOUSB registry plane from the registry
/// root. Walking from the root (rather than matching IOUSBHostDevice and
/// climbing parents) is load-bearing: idle controllers have no devices to
/// climb from and would vanish, taking their section headers and empty-port
/// anchors with them.
public enum USBTopologyBuilder {

    public static func build() -> [DeviceNode] {
        let root = Registry.rootEntry()
        defer { IOObjectRelease(root) }
        let controllers = Registry.children(of: root, plane: "IOUSB")
        var portStats: [UInt64: [String: PropertyValue]] = [:]
        var nodes: [DeviceNode] = []
        for controller in controllers {
            nodes.append(buildController(controller, portStats: &portStats))
            IOObjectRelease(controller)
        }
        // Pair USB2/USB3 hub twin personalities per controller subtree, and
        // order controllers as receptacles first (by bus), internal last.
        return nodes.map { controller in
            var merged = controller
            merged.children = mergeTwinSiblings(controller.children)
            return applyPortStats(portStats, to: merged)
        }
        .sorted { a, b in
            let aInternal = a.name.hasPrefix("Internal"), bInternal = b.name.hasPrefix("Internal")
            if aInternal != bInternal { return bInternal }
            return (a.locationID ?? 0) < (b.locationID ?? 0)
        }
    }

    /// The IOService-plane port object between a hub/controller and each
    /// attached device carries error counters (overcurrent, enumeration /
    /// address failures, link errors) — merged into the downstream device's
    /// property bag under "Port …" keys so the Raw tab and Doctor both see
    /// them.
    struct PortSummary {
        var total: Int64 = 0
        var free: Int64 = 0
        var freeNumbers: [Int64] = []
    }

    private static func collectPortStats(
        under entry: io_registry_entry_t,
        into stats: inout [UInt64: [String: PropertyValue]],
        summary: inout PortSummary,
        depth: Int = 0
    ) {
        // Port objects sit at varying depths: controller → usb-drd*-port-*,
        // but hub device → interface → hub driver → AppleUSB*HubPort. Recurse,
        // stopping at child devices (each hub scans its own port subtree).
        guard depth <= 4 else { return }
        let children = Registry.children(of: entry, plane: "IOService")
        defer { children.forEach { IOObjectRelease($0) } }
        for child in children {
            if Registry.conforms(child, to: "IOUSBHostDevice") { continue }
            let props = Registry.properties(of: child)
            if case .dict(let counters)? = props["port-statistics"] {
                var merged: [String: PropertyValue] = [:]
                for (key, value) in counters where key != "kPortStatPowerStateTime" {
                    merged["Port \(key)"] = value
                }
                if let limit = props["kUSBWakePortCurrentLimit"] { merged["Port kUSBWakePortCurrentLimit"] = limit }
                if let linkErrors = props["link-error-count"] { merged["Port link-error-count"] = linkErrors }

                var occupied = false
                let downstream = Registry.children(of: child, plane: "IOService")
                defer { downstream.forEach { IOObjectRelease($0) } }
                for device in downstream where Registry.conforms(device, to: "IOUSBHostDevice") {
                    occupied = true
                    stats[Registry.entryID(of: device), default: [:]].merge(merged) { a, _ in a }
                }
                // Occupancy: every port object counts once; free ports keep
                // their number so "plug it into port N" is actionable.
                summary.total += 1
                if !occupied {
                    summary.free += 1
                    let number = pciLEInt(props["port"]) ?? pciLEInt(props["usb-port-number"]) ?? 0
                    if number > 0 { summary.freeNumbers.append(number) }
                }
            }
            collectPortStats(under: child, into: &stats, summary: &summary, depth: depth + 1)
        }
    }

    private static func applyPortStats(
        _ stats: [UInt64: [String: PropertyValue]],
        to node: DeviceNode
    ) -> DeviceNode {
        guard !stats.isEmpty else { return node }
        var out = node
        if let extra = stats[node.id] ?? node.twin.flatMap({ stats[$0.secondaryID] }) {
            var props = node.properties
            props.merge(extra) { a, _ in a }
            out = DeviceNode(
                id: node.id, kind: node.kind, name: node.name, subtitle: node.subtitle,
                className: node.className, category: node.category, tier: node.tier,
                speedLabel: node.speedLabel, linkSpeedBps: node.linkSpeedBps,
                properties: props, interfaces: node.interfaces, children: node.children,
                twin: node.twin, crossLinkID: node.crossLinkID
            )
        }
        out.children = out.children.map { applyPortStats(stats, to: $0) }
        return out
    }

    // MARK: - Node construction

    private static func buildController(
        _ entry: io_registry_entry_t,
        portStats: inout [UInt64: [String: PropertyValue]]
    ) -> DeviceNode {
        let props = Registry.properties(of: entry)
        let className = Registry.className(of: entry)
        let registryName = Registry.name(of: entry)
        var controllerPorts = PortSummary()
        collectPortStats(under: entry, into: &portStats, summary: &controllerPorts)
        var children: [DeviceNode] = []
        for child in Registry.children(of: entry, plane: "IOUSB") {
            defer { IOObjectRelease(child) }
            children.append(buildDevice(child, portStats: &portStats))
        }
        let busNumber = (props["locationID"]?.intValue).map { ($0 >> 24) & 0xFF }
        let name: String
        if className.contains("AUSS") || busNumber == 8 {
            name = "Internal controller"
        } else if let bus = busNumber {
            name = "Receptacle \(bus + 1) (bus \(bus))"
        } else {
            name = registryName
        }
        var subtitle = className
        if let rev = props["UsbHostControllerProtocolRevision"]?.stringValue {
            subtitle += " · USB \(rev)"
        }
        return DeviceNode(
            id: Registry.entryID(of: entry),
            kind: .usbController,
            name: name,
            subtitle: subtitle,
            className: className,
            category: .controller,
            tier: .infrastructure,
            speedLabel: children.isEmpty ? "idle" : "",
            linkSpeedBps: 0,
            properties: props,
            children: children.sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
        )
    }

    private static func buildDevice(
        _ entry: io_registry_entry_t,
        portStats: inout [UInt64: [String: PropertyValue]]
    ) -> DeviceNode {
        var props = Registry.properties(of: entry)
        let registryName = Registry.name(of: entry)
        let interfaces = collectInterfaces(of: entry)
        if props["bDeviceClass"]?.intValue == 9 {
            var hubPorts = PortSummary()
            collectPortStats(under: entry, into: &portStats, summary: &hubPorts)
            if hubPorts.total > 0 {
                props["Portree Ports Total"] = .int(hubPorts.total)
                props["Portree Ports Free"] = .int(hubPorts.free)
                if !hubPorts.freeNumbers.isEmpty {
                    props["Portree Free Ports"] = .string(
                        hubPorts.freeNumbers.sorted().map { "\($0)" }.joined(separator: ", ")
                    )
                }
            }
        }
        var children: [DeviceNode] = []
        for child in Registry.children(of: entry, plane: "IOUSB") {
            defer { IOObjectRelease(child) }
            children.append(buildDevice(child, portStats: &portStats))
        }

        let linkSpeed = props["UsbLinkSpeed"]?.intValue ?? 0
        var (name, subtitle) = displayName(props: props, registryName: registryName)
        // Port number on the parent = last nibble of the locationID path.
        if let location = props["locationID"]?.intValue, let port = Format.lastPort(locationID: location) {
            subtitle = subtitle.isEmpty ? "port \(port)" : "port \(port) · \(subtitle)"
        }
        return DeviceNode(
            id: Registry.entryID(of: entry),
            kind: .usbDevice,
            name: name,
            subtitle: subtitle,
            className: Registry.className(of: entry),
            category: classify(props: props, interfaces: interfaces, name: name),
            tier: Format.tier(forBps: linkSpeed),
            speedLabel: Format.speedLabel(bps: linkSpeed),
            linkSpeedBps: linkSpeed,
            properties: props,
            interfaces: interfaces,
            children: children.sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
        )
    }

    private static func collectInterfaces(of entry: io_registry_entry_t) -> [SubEntry] {
        // Interfaces live in the IOService plane (the IOUSB plane holds devices only).
        let children = Registry.children(of: entry, plane: "IOService")
        defer { children.forEach { IOObjectRelease($0) } }
        return children.enumerated().compactMap { index, child in
            guard Registry.conforms(child, to: "IOUSBHostInterface") else { return nil }
            let props = Registry.properties(of: child)
            let number = props["bInterfaceNumber"]?.intValue ?? Int64(index)
            let cls = props["bInterfaceClass"]?.intValue ?? 0
            let sub = props["bInterfaceSubClass"]?.intValue ?? 0
            let proto = props["bInterfaceProtocol"]?.intValue ?? 0
            let endpoints = props["bNumEndpoints"]?.intValue ?? 0
            let ifName = props["kUSBString"]?.stringValue ?? Registry.name(of: child)
            var detail = Format.usbClassName(cls)
                + String(format: " (%02llX/%02llX/%02llX)", cls, sub, proto)
                + " · \(endpoints) endpoint\(endpoints == 1 ? "" : "s")"
            if let owner = props["UsbExclusiveOwner"]?.stringValue {
                detail += " · owner: \(owner)"
            }
            let title = ifName.isEmpty ? "Interface \(number)" : "ifc \(number) — \(ifName)"
            return SubEntry(
                id: "if-\(Registry.entryID(of: child))",
                title: title,
                detail: detail,
                properties: props
            )
        }
    }

    // MARK: - Naming & classification

    /// Fallback chain: USB Product Name → vendor + VID:PID → registry name →
    /// class label. Never empty, never dependent on usb.ids.
    private static func displayName(props: [String: PropertyValue], registryName: String) -> (String, String) {
        let vendor = props["USB Vendor Name"]?.stringValue ?? props["kUSBVendorString"]?.stringValue
        let product = props["USB Product Name"]?.stringValue ?? props["kUSBProductString"]?.stringValue
        let vid = props["idVendor"]?.intValue
        let pid = props["idProduct"]?.intValue
        let vidPid = (vid != nil && pid != nil) ? "\(Format.hex(vid!, width: 4)):\(Format.hex(pid!, width: 4))" : nil

        var name = product ?? ""
        if name.isEmpty, let vendor, let vidPid { name = "\(vendor) \(vidPid)" }
        if name.isEmpty { name = registryName }
        if name.isEmpty, let cls = props["bDeviceClass"]?.intValue { name = Format.usbClassName(cls) }
        if name.isEmpty { name = "USB device" }

        var subtitle = vendor ?? ""
        if let vidPid { subtitle += subtitle.isEmpty ? vidPid : " · \(vidPid)" }
        return (name, subtitle)
    }

    private static func classify(props: [String: PropertyValue], interfaces: [SubEntry], name: String) -> DeviceCategory {
        let lowered = name.lowercased()
        let classCode = props["bDeviceClass"]?.intValue ?? 0
        switch classCode {
        case 0x09: return .hub
        case 0x03: return hidFamily(interfaces: interfaces, lowered: lowered)
        case 0x08: return .storage
        case 0x01, 0x10: return audioFamily(lowered: lowered)
        case 0x06, 0x0E: return .video
        case 0x02, 0x0A: return .network
        case 0x07: return .printer
        case 0x0B: return .smartCard
        case 0xE0: return .wireless
        case 0x11: return .display
        case 0xFF: return .vendor
        default: break
        }
        // Composite/miscellaneous: infer from interfaces, then the name.
        let interfaceClasses = Set(interfaces.compactMap { $0.properties["bInterfaceClass"]?.intValue })
        if interfaceClasses.contains(0xE0) || lowered.contains("bluetooth") { return .wireless }
        if interfaceClasses.contains(0x08) { return .storage }
        if interfaceClasses.contains(0x07) { return .printer }
        if interfaceClasses.contains(0x0B) { return .smartCard }
        if interfaceClasses.contains(0x06) || interfaceClasses.contains(0x0E) { return .video }
        if interfaceClasses.contains(0x01) { return audioFamily(lowered: lowered) }
        if interfaceClasses.contains(0x02) || interfaceClasses.contains(0x0A) { return .network }
        if interfaceClasses.contains(0x03) { return hidFamily(interfaces: interfaces, lowered: lowered) }
        if lowered.contains("lan") || lowered.contains("ethernet") { return .network }
        if lowered.contains("hub") { return .hub }
        if lowered.contains("keyboard") { return .hid }
        if lowered.contains("mouse") || lowered.contains("trackpad") || lowered.contains("receiver") { return .mouse }
        if lowered.contains("camera") { return .video }
        if lowered.contains("print") { return .printer }
        return classCode == 0 ? .unknown : .vendor
    }

    /// HID boot protocol tells keyboard (1) from mouse (2); names break ties.
    private static func hidFamily(interfaces: [SubEntry], lowered: String) -> DeviceCategory {
        if lowered.contains("mouse") || lowered.contains("trackpad") || lowered.contains("receiver") { return .mouse }
        if lowered.contains("keyboard") { return .hid }
        let protocols = interfaces.compactMap { entry -> Int64? in
            guard entry.properties["bInterfaceClass"]?.intValue == 3,
                  entry.properties["bInterfaceSubClass"]?.intValue == 1 else { return nil }
            return entry.properties["bInterfaceProtocol"]?.intValue
        }
        if protocols.contains(2) && !protocols.contains(1) { return .mouse }
        return .hid
    }

    private static func audioFamily(lowered: String) -> DeviceCategory {
        if lowered.contains("speaker") || lowered.contains("headphone") || lowered.contains("headset") {
            return .speaker
        }
        return .audio
    }

    // MARK: - Hub-twin merge

    /// A USB3 hub is two logical devices (USB2 + USB3 personalities in
    /// parallel subtrees). Merge guards (all required): both class 9, same
    /// kUSBContainerID, siblings (⇒ same controller), and a ≤480M / ≥5G speed
    /// split. The high-speed personality is canonical; children are the union
    /// of both, re-paired recursively (the Dell fan-out pairs at every tier).
    static func mergeTwinSiblings(_ siblings: [DeviceNode]) -> [DeviceNode] {
        var consumed = Set<UInt64>()
        var result: [DeviceNode] = []
        for node in siblings {
            if consumed.contains(node.id) { continue }
            guard node.isHub,
                  let container = node.containerIDKey,
                  let partner = siblings.first(where: {
                      $0.id != node.id && !consumed.contains($0.id) && $0.isHub && $0.containerIDKey == container
                  }),
                  isSpeedSplit(node, partner)
            else {
                var kept = node
                kept.children = mergeTwinSiblings(node.children)
                result.append(kept)
                continue
            }
            let (low, high) = node.linkSpeedBps < partner.linkSpeedBps ? (node, partner) : (partner, node)
            consumed.insert(low.id)
            consumed.insert(high.id)
            var merged = high
            merged.twin = TwinInfo(
                secondaryID: low.id,
                secondaryName: low.name,
                lowSpeedBps: low.linkSpeedBps,
                highSpeedBps: high.linkSpeedBps
            )
            merged.children = mergeTwinSiblings(high.children + low.children)
            result.append(merged)
        }
        return result
    }

    /// 4-byte little-endian Data (how port objects store "port" /
    /// "usb-port-number") or a plain number.
    private static func pciLEInt(_ value: PropertyValue?) -> Int64? {
        switch value {
        case .int(let i): return i
        case .data(let d) where !d.isEmpty:
            return d.prefix(8).enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * $1.offset) }
        default: return nil
        }
    }

    private static func isSpeedSplit(_ a: DeviceNode, _ b: DeviceNode) -> Bool {
        let low = min(a.linkSpeedBps, b.linkSpeedBps)
        let high = max(a.linkSpeedBps, b.linkSpeedBps)
        return low > 0 && low <= 480_000_000 && high >= 5_000_000_000
    }
}
