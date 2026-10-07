import Foundation
import IOKit

/// Builds the Thunderbolt/USB4 fabric tree. Matching uses BASE classes only
/// (IOThunderboltController / IOThunderboltSwitch / IOThunderboltPort) —
/// concrete classes vary per device (IOThunderboltSwitchType7 = Mac root,
/// IOThunderboltSwitchIntelJHL8440 = Dell U2725QE, IOThunderboltSwitchType3 =
/// Cable Matters). The registry parent chain alternates
/// switch → host port → (child) device upstream port → device switch.
public enum TBTopologyBuilder {

    public static func build() -> [DeviceNode] {
        let controllers = Registry.matchingServices("IOThunderboltController")
        defer { controllers.forEach { IOObjectRelease($0) } }
        return controllers.compactMap(buildDomain).sorted { $0.name < $1.name }
    }

    private static func buildDomain(_ controller: io_object_t) -> DeviceNode? {
        let props = Registry.properties(of: controller)
        var domainUUID: String?
        var rootSwitch: DeviceNode?

        let children = Registry.children(of: controller, plane: "IOService")
        defer { children.forEach { IOObjectRelease($0) } }
        for child in children {
            if Registry.conforms(child, to: "IOThunderboltLocalNode") {
                domainUUID = Registry.properties(of: child)["Domain UUID"]?.stringValue
            }
            if rootSwitch == nil, let found = findSwitch(under: child, depth: 0) {
                rootSwitch = found
            }
        }

        let socket = rootSwitch.flatMap(socketID)
        let name = socket.map { "Thunderbolt/USB4 — Receptacle \($0)" } ?? "Thunderbolt/USB4 domain"
        let capability = rootSwitch.map(domainCapabilityLabel) ?? ""
        var domainProps = props
        if let domainUUID { domainProps["Domain UUID"] = .string(domainUUID) }

        return DeviceNode(
            id: Registry.entryID(of: controller),
            kind: .tbDomain,
            name: name,
            subtitle: Registry.className(of: controller) + (domainUUID.map { " · \($0)" } ?? ""),
            className: Registry.className(of: controller),
            category: .tbDomain,
            tier: .infrastructure,
            speedLabel: capability,
            linkSpeedBps: 0,
            properties: domainProps,
            children: rootSwitch.map { [$0] } ?? []
        )
    }

    /// First IOThunderboltSwitch in the subtree (bounded depth — the root
    /// switch sits a couple of hops below the controller).
    private static func findSwitch(under entry: io_object_t, depth: Int) -> DeviceNode? {
        if Registry.conforms(entry, to: "IOThunderboltSwitch") {
            return buildSwitch(entry)
        }
        guard depth < 4 else { return nil }
        let children = Registry.children(of: entry, plane: "IOService")
        defer { children.forEach { IOObjectRelease($0) } }
        for child in children {
            if let found = findSwitch(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func buildSwitch(_ entry: io_object_t, inheritedLinkTenths: Int64 = 0) -> DeviceNode {
        let props = Registry.properties(of: entry)
        var ports: [SubEntry] = []
        var childSwitches: [DeviceNode] = []
        var activeLinkTenthsGbps: Int64 = 0

        let children = Registry.children(of: entry, plane: "IOService")
        defer { children.forEach { IOObjectRelease($0) } }
        for port in children {
            guard Registry.conforms(port, to: "IOThunderboltPort") else { continue }
            let portProps = Registry.properties(of: port)
            ports.append(portEntry(port, portProps))

            // Active lane-port link speed: Link Bandwidth is in 0.1 Gb/s units
            // (400 = 40G); idle TB5 lane ports report 100 with Current Link
            // Speed 0, so require an actual trained link.
            var portLinkTenths: Int64 = 0
            if let bandwidth = portProps["Link Bandwidth"]?.intValue,
               let current = portProps["Current Link Speed"]?.intValue, current > 0 {
                activeLinkTenthsGbps = max(activeLinkTenthsGbps, bandwidth)
                portLinkTenths = bandwidth
            }

            // Downstream: host lane port → child port (device upstream) → switch.
            // Downstream switches may not expose a trained link themselves
            // (observed on the Cable Matters TB3 adapter) — they inherit the
            // connecting port's trained bandwidth.
            let grandchildren = Registry.children(of: port, plane: "IOService")
            defer { grandchildren.forEach { IOObjectRelease($0) } }
            for sub in grandchildren {
                if Registry.conforms(sub, to: "IOThunderboltSwitch") {
                    childSwitches.append(buildSwitch(sub, inheritedLinkTenths: portLinkTenths))
                } else if Registry.conforms(sub, to: "IOThunderboltPort") {
                    let deeper = Registry.children(of: sub, plane: "IOService")
                    defer { deeper.forEach { IOObjectRelease($0) } }
                    for candidate in deeper where Registry.conforms(candidate, to: "IOThunderboltSwitch") {
                        childSwitches.append(buildSwitch(candidate, inheritedLinkTenths: portLinkTenths))
                    }
                }
            }
        }
        if activeLinkTenthsGbps == 0 { activeLinkTenthsGbps = inheritedLinkTenths }

        let vendor = props["Device Vendor Name"]?.stringValue ?? props["Vendor Name"]?.stringValue
        let uid = props["UID"]?.intValue
        let depth = props["Depth"]?.intValue ?? 0
        let isRoot = depth == 0
        // Apple Silicon host switches self-report Device Model Name = "iOS";
        // ignore the model at depth 0.
        let model = isRoot ? nil : props["Device Model Name"]?.stringValue

        var name = model ?? ""
        if name.isEmpty, isRoot { name = "Host switch" }
        if name.isEmpty, let vendor { name = vendor }
        if name.isEmpty, let uid { name = "Switch \(Format.tbUID(uid))" }
        if name.isEmpty { name = Registry.name(of: entry) }

        var subtitleParts: [String] = []
        if let vendor, model != nil { subtitleParts.append(vendor) }
        if let route = props["Route String"]?.intValue {
            subtitleParts.append("route \(Format.hex(route))")
        }
        if let rom = props["ROM Version"]?.intValue, let eeprom = props["EEPROM Revision"]?.intValue {
            subtitleParts.append("NVM \(Format.nvmVersion(rom: rom, eeprom: eeprom))")
        }

        let speedLabel = activeLinkTenthsGbps > 0
            ? Format.tbLinkBandwidthLabel(tenthsGbps: activeLinkTenthsGbps)
            : (isRoot ? domainCapabilityFromPorts(ports) : "")

        return DeviceNode(
            id: Registry.entryID(of: entry),
            kind: .tbSwitch,
            name: name,
            subtitle: subtitleParts.joined(separator: " · "),
            className: Registry.className(of: entry),
            category: .tbSwitch,
            tier: activeLinkTenthsGbps > 0 ? .thunderbolt : .infrastructure,
            speedLabel: speedLabel,
            linkSpeedBps: activeLinkTenthsGbps * 100_000_000,
            properties: props,
            interfaces: ports,
            children: childSwitches
        )
    }

    private static func portEntry(_ port: io_object_t, _ props: [String: PropertyValue]) -> SubEntry {
        let number = props["Port Number"]?.intValue ?? 0
        let description = props["Description"]?.stringValue ?? "Port"
        var details: [String] = []
        if let socket = props["Socket ID"]?.stringValue ?? props["Socket ID"]?.intValue.map({ "\($0)" }) {
            details.append("receptacle \(socket)")
        }
        if let bandwidth = props["Link Bandwidth"]?.intValue {
            details.append("bandwidth \(Format.tbLinkBandwidthLabel(tenthsGbps: bandwidth))")
        }
        if let speed = props["Current Link Speed"]?.intValue, let width = props["Current Link Width"]?.intValue {
            details.append(speed > 0 ? "trained ×\(width) (speed \(speed))" : "idle")
        }
        if let supported = props["Supported Link Speed"]?.intValue {
            details.append(supported >= 14 ? "TB5-class" : (supported >= 12 ? "40G-class" : "supported \(supported)"))
        }
        return SubEntry(
            id: "port-\(Registry.entryID(of: port))",
            title: "Port \(number) — \(description)",
            detail: details.joined(separator: " · "),
            properties: props
        )
    }

    private static func socketID(_ node: DeviceNode) -> String? {
        for port in node.interfaces {
            if let socket = port.properties["Socket ID"]?.stringValue { return socket }
            if let socket = port.properties["Socket ID"]?.intValue { return "\(socket)" }
        }
        return nil
    }

    /// "Up to N Gb/s" for an idle domain, from the best NHI/lane-port
    /// Link Bandwidth (1200 = TB5 120 Gb/s capability).
    private static func domainCapabilityLabel(_ root: DeviceNode) -> String {
        domainCapabilityFromPorts(root.interfaces)
    }

    private static func domainCapabilityFromPorts(_ ports: [SubEntry]) -> String {
        let best = ports.compactMap { $0.properties["Link Bandwidth"]?.intValue }.max() ?? 0
        guard best > 100 else { return "" }
        return "up to \(Format.tbLinkBandwidthLabel(tenthsGbps: best))"
    }
}
