import Foundation
import IOKit

/// PCIe layer: every IOPCIDevice (bridges included), with link generation and
/// lane width decoded from the Express link registers, tunneled devices
/// cross-linked to the Thunderbolt port that carries them. On Apple Silicon
/// the built-in controllers are SoC-fabric devices — only tunneled/bridged
/// hardware appears here, which is itself the honest answer.
public enum PCITopologyBuilder {

    public static func build(tbRoots: [DeviceNode]) -> [DeviceNode] {
        // TB port entry ID → owning switch node ID, for Thunderbolt Entry ID
        // cross-links (SubEntry ids are "port-<entryID>").
        var portOwner: [UInt64: UInt64] = [:]
        func harvest(_ node: DeviceNode) {
            for entry in node.interfaces where entry.id.hasPrefix("port-") {
                if let portID = UInt64(entry.id.dropFirst(5)) { portOwner[portID] = node.id }
            }
            node.children.forEach(harvest)
        }
        tbRoots.forEach(harvest)

        let services = Registry.matchingServices("IOPCIDevice")
        defer { services.forEach { IOObjectRelease($0) } }

        var nodes: [UInt64: DeviceNode] = [:]
        var parentOf: [UInt64: UInt64] = [:]
        let allIDs = Set(services.map { Registry.entryID(of: $0) })

        for service in services {
            let id = Registry.entryID(of: service)
            nodes[id] = buildNode(service, portOwner: portOwner)
            if let parentID = pciParentID(of: service), allIDs.contains(parentID) {
                parentOf[id] = parentID
            }
        }

        // NVMe controllers: real storage devices behind PCIe functions (TB/USB4
        // enclosures) or straight on the SoC fabric (internal Apple NVMe).
        var nvmeRoots: [DeviceNode] = []
        let nvmeControllers = Registry.matchingServices("IONVMeController")
        defer { nvmeControllers.forEach { IOObjectRelease($0) } }
        for controller in nvmeControllers {
            let node = buildNVMe(controller)
            if let parentID = Registry.ancestorID(of: controller, conformingToAny: ["IOPCIDevice"], maxDepth: 6),
               nodes[parentID] != nil {
                parentOf[node.id] = parentID
                nodes[node.id] = node
            } else {
                nvmeRoots.append(node)   // SoC-fabric NVMe: no PCIe path, honestly so
            }
        }

        // Assemble children bottom-up (sort for stable output).
        var childIDs: [UInt64: [UInt64]] = [:]
        for (child, parent) in parentOf { childIDs[parent, default: []].append(child) }
        func assemble(_ id: UInt64) -> DeviceNode {
            var node = nodes[id]!
            node.children = (childIDs[id] ?? []).sorted().map(assemble)
            return node
        }
        return nodes.keys.filter { parentOf[$0] == nil }.sorted().map(assemble) + nvmeRoots
    }

    private static func buildNVMe(_ controller: io_object_t) -> DeviceNode {
        let props = Registry.properties(of: controller)
        let model = (props["Model Number"]?.stringValue ?? Registry.name(of: controller))
            .trimmingCharacters(in: .whitespaces)
        let serial = (props["Serial Number"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let firmware = (props["Firmware Revision"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let tunneled = props["IOPCITunnelled"]?.boolValue == true

        // The registry says where this controller really hangs: internal
        // Apple Silicon NVMe reports "Apple Fabric" (the ANS coprocessor on
        // the SoC — not PCIe), while enclosure NVMe sits behind tunneled
        // PCIe bridges. Surface that so the standalone placement reads as
        // truth, not a layout bug.
        let interconnect = props["Physical Interconnect"]?.stringValue ?? "NVMe"
        let location = props["Physical Interconnect Location"]?.stringValue
        let onFabric = interconnect == "Apple Fabric"

        var subtitleParts = ["NVMe"]
        if let location { subtitleParts.append(location) }
        if !firmware.isEmpty { subtitleParts.append("fw \(firmware)") }
        if !serial.isEmpty { subtitleParts.append(serial) }

        return DeviceNode(
            id: Registry.entryID(of: controller),
            kind: .pciDevice,
            name: model.isEmpty ? "NVMe controller" : model,
            subtitle: subtitleParts.joined(separator: " · "),
            className: Registry.className(of: controller),
            category: .storage,
            tier: tunneled ? .thunderbolt : (onFabric ? .fabric : .infrastructure),
            speedLabel: interconnect,
            linkSpeedBps: 0,
            properties: props
        )
    }

    private static func pciParentID(of service: io_object_t) -> UInt64? {
        Registry.ancestorID(of: service, conformingToAny: ["IOPCIDevice"], maxDepth: 6)
    }

    private static func buildNode(_ service: io_object_t, portOwner: [UInt64: UInt64]) -> DeviceNode {
        let props = Registry.properties(of: service)
        let registryName = Registry.name(of: service)

        let vendorID = pciID(props["vendor-id"])
        let deviceID = pciID(props["device-id"])
        let classCode = pciID(props["class-code"])
        let tunneled = props["IOPCITunnelled"]?.boolValue == true

        let (gen, width) = decodeLink(props["IOPCIExpressLinkStatus"]?.intValue)
        let (maxGen, maxWidth) = decodeLink(props["IOPCIExpressLinkCapabilities"]?.intValue)

        var speedLabel = ""
        if let gen, let width {
            speedLabel = "Gen\(gen) ×\(width)"
            if let maxGen, let maxWidth, (maxGen > gen || maxWidth > width) {
                speedLabel += " (cap Gen\(maxGen) ×\(maxWidth))"
            }
        }

        var subtitleParts: [String] = []
        if let classCode { subtitleParts.append(className(classCode)) }
        if let vendorID, let deviceID {
            subtitleParts.append("\(Format.hex(vendorID, width: 4)):\(Format.hex(deviceID, width: 4))")
        }
        if tunneled { subtitleParts.append("TB tunnel") }

        let crossLink = props["Thunderbolt Entry ID"]?.intValue
            .flatMap { portOwner[UInt64(bitPattern: $0)] }

        return DeviceNode(
            id: Registry.entryID(of: service),
            kind: .pciDevice,
            name: props["IOName"]?.stringValue ?? registryName,
            subtitle: subtitleParts.joined(separator: " · "),
            className: Registry.className(of: service),
            category: category(forClassCode: classCode),
            tier: tunneled ? .thunderbolt : .infrastructure,
            speedLabel: speedLabel,
            linkSpeedBps: gen.map { linkBps(gen: $0, width: width ?? 1) } ?? 0,
            properties: props,
            crossLinkID: crossLink
        )
    }

    /// The icon should say what the device IS, not just "PCI".
    private static func category(forClassCode code: Int64?) -> DeviceCategory {
        guard let code else { return .pci }
        switch (code >> 8) & 0xFFFF {
        case 0x0108, 0x0100, 0x0106, 0x0805: return .storage
        case 0x0C03: return .controller
        case 0x0200, 0x0280, 0x0D11, 0x0D20, 0x0D21, 0x0D80: return .network
        case 0x0300, 0x0380: return .display
        case 0x0403: return .audio
        default: return .pci
        }
    }

    /// vendor-id / device-id / class-code arrive as 4-byte little-endian Data
    /// on Apple Silicon (or occasionally as plain numbers).
    private static func pciID(_ value: PropertyValue?) -> Int64? {
        switch value {
        case .int(let i): return i
        case .data(let d) where d.count >= 4:
            return Int64(d[d.startIndex])
                | Int64(d[d.startIndex + 1]) << 8
                | Int64(d[d.startIndex + 2]) << 16
                | Int64(d[d.startIndex + 3]) << 24
        default: return nil
        }
    }

    /// PCIe link registers: bits [3:0] speed (1→2.5 GT/s … 5→32 GT/s),
    /// bits [9:4] width. Apple fabric bridges report all-ones dummies
    /// ("Gen15 ×63") — out-of-spec values mean "no real PCIe link", not data.
    private static func decodeLink(_ register: Int64?) -> (gen: Int?, width: Int?) {
        guard let register, register > 0 else { return (nil, nil) }
        let speed = Int(register & 0xF)
        let width = Int((register >> 4) & 0x3F)
        let validWidths: Set<Int> = [1, 2, 4, 8, 12, 16, 32]
        guard (1...7).contains(speed), validWidths.contains(width) else { return (nil, nil) }
        return (speed, width)
    }

    private static func linkBps(gen: Int, width: Int) -> Int64 {
        // Per-lane effective rates (GT/s with encoding overhead folded in).
        let perLaneMbps: Int64
        switch gen {
        case 1: perLaneMbps = 2_000
        case 2: perLaneMbps = 4_000
        case 3: perLaneMbps = 7_877
        case 4: perLaneMbps = 15_754
        default: perLaneMbps = 31_508
        }
        return perLaneMbps * 1_000_000 * Int64(width)
    }

    private static func className(_ code: Int64) -> String {
        switch (code >> 8) & 0xFFFF {
        case 0x0604: return "PCI bridge"
        case 0x0108: return "NVMe storage"
        case 0x0805: return "SD host controller"
        case 0x0C03: return "USB controller"
        case 0x0200: return "Ethernet"
        case 0x0280: return "Network"
        case 0x0D11, 0x0D20, 0x0D21, 0x0D80: return "Wireless"
        case 0x0300, 0x0380: return "Display"
        case 0x0403: return "Audio"
        default: return "PCI device (\(Format.hex(code, width: 6)))"
        }
    }
}
