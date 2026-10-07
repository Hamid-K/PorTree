import Foundation

/// Static host context: the SoC the controllers hang off. There is no public
/// API for internal fabric utilization on Apple Silicon, so this node is
/// identity only — it never shows invented load numbers.
public enum SystemInfo {

    /// Stable synthetic ID — IORegistry entry IDs are large, 1 is never one.
    public static let nodeID: UInt64 = 1

    public static func node() -> DeviceNode {
        var props: [String: PropertyValue] = [:]
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let model = sysctlString("hw.model") ?? ""
        let osVersion = sysctlString("kern.osproductversion") ?? ""
        let cores = sysctlInt("hw.ncpu") ?? 0
        let perfCores = sysctlInt("hw.perflevel0.physicalcpu")
        let effCores = sysctlInt("hw.perflevel1.physicalcpu")
        let memBytes = sysctlInt("hw.memsize") ?? 0

        props["Chip"] = .string(chip)
        if !model.isEmpty { props["Model identifier"] = .string(model) }
        if !osVersion.isEmpty { props["macOS"] = .string(osVersion) }
        props["CPU cores"] = .string(
            perfCores != nil && effCores != nil
                ? "\(cores) (\(perfCores!) performance + \(effCores!) efficiency)"
                : "\(cores)"
        )
        if memBytes > 0 { props["Memory"] = .string("\(memBytes / (1 << 30)) GB") }
        props["Note"] = .string("Built-in XHCI controllers sit on the SoC fabric, not PCIe. Internal fabric utilization has no public API.")

        return DeviceNode(
            id: nodeID,
            kind: .system,
            name: chip,
            subtitle: model.isEmpty ? "This Mac" : model,
            className: "System",
            category: .system,
            tier: .infrastructure,
            speedLabel: "",
            linkSpeedBps: 0,
            properties: props
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
