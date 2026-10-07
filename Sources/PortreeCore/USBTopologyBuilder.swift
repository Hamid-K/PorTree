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
        var nodes: [DeviceNode] = []
        for controller in controllers {
            nodes.append(buildController(controller))
            IOObjectRelease(controller)
        }
        // Pair USB2/USB3 hub twin personalities per controller subtree, and
        // order controllers as receptacles first (by bus), internal last.
        return nodes.map { controller in
            var merged = controller
            merged.children = mergeTwinSiblings(controller.children)
            return merged
        }
        .sorted { a, b in
            let aInternal = a.name.hasPrefix("Internal"), bInternal = b.name.hasPrefix("Internal")
            if aInternal != bInternal { return bInternal }
            return (a.locationID ?? 0) < (b.locationID ?? 0)
        }
    }

    // MARK: - Node construction

    private static func buildController(_ entry: io_registry_entry_t) -> DeviceNode {
        let props = Registry.properties(of: entry)
        let className = Registry.className(of: entry)
        let registryName = Registry.name(of: entry)
        let children = Registry.children(of: entry, plane: "IOUSB").map { child -> DeviceNode in
            defer { IOObjectRelease(child) }
            return buildDevice(child)
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

    private static func buildDevice(_ entry: io_registry_entry_t) -> DeviceNode {
        let props = Registry.properties(of: entry)
        let registryName = Registry.name(of: entry)
        let interfaces = collectInterfaces(of: entry)
        let children = Registry.children(of: entry, plane: "IOUSB").map { child -> DeviceNode in
            defer { IOObjectRelease(child) }
            return buildDevice(child)
        }

        let linkSpeed = props["UsbLinkSpeed"]?.intValue ?? 0
        let (name, subtitle) = displayName(props: props, registryName: registryName)
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
        let classCode = props["bDeviceClass"]?.intValue ?? 0
        switch classCode {
        case 0x09: return .hub
        case 0x03: return .hid
        case 0x08: return .storage
        case 0x01, 0x10: return .audio
        case 0x06, 0x0E: return .video
        case 0x02, 0x0A: return .network
        case 0x11: return .display
        case 0xFF: return .vendor
        default: break
        }
        // Composite/miscellaneous: infer from interfaces, then the name.
        let interfaceClasses = Set(interfaces.compactMap { $0.properties["bInterfaceClass"]?.intValue })
        if interfaceClasses.contains(0x08) { return .storage }
        if interfaceClasses.contains(0x06) || interfaceClasses.contains(0x0E) { return .video }
        if interfaceClasses.contains(0x01) { return .audio }
        if interfaceClasses.contains(0x02) || interfaceClasses.contains(0x0A) { return .network }
        if interfaceClasses.contains(0x03) { return .hid }
        let lowered = name.lowercased()
        if lowered.contains("lan") || lowered.contains("ethernet") { return .network }
        if lowered.contains("hub") { return .hub }
        if lowered.contains("keyboard") || lowered.contains("mouse") || lowered.contains("receiver") { return .hid }
        return classCode == 0 ? .unknown : .vendor
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

    private static func isSpeedSplit(_ a: DeviceNode, _ b: DeviceNode) -> Bool {
        let low = min(a.linkSpeedBps, b.linkSpeedBps)
        let high = max(a.linkSpeedBps, b.linkSpeedBps)
        return low > 0 && low <= 480_000_000 && high >= 5_000_000_000
    }
}
