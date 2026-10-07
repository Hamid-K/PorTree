import Foundation

/// Static host context: the SoC the controllers hang off. There is no public
/// API for internal fabric utilization on Apple Silicon, so this node is
/// identity only — it never shows invented load numbers.
public enum SystemInfo {

    /// Stable synthetic ID — IORegistry entry IDs are large, 1 is never one.
    public static let nodeID: UInt64 = 1

    /// Reference specs per chip family — static knowledge, so entries exist
    /// only for chips the table knows; unknown chips omit the rows rather
    /// than guess. Measured Thunderbolt capability (from the live registry)
    /// is injected separately by Snapshot.capture.
    private static let chipSpecs: [(match: String, thunderbolt: String, displays: String)] = [
        ("M1 Ultra", "Thunderbolt 4 · 40 Gb/s", "up to 5 external displays"),
        ("M1 Max", "Thunderbolt 4 · 40 Gb/s", "up to 4 external displays"),
        ("M1 Pro", "Thunderbolt 4 · 40 Gb/s", "up to 2 external displays"),
        ("M1", "Thunderbolt 3 / USB4 · 40 Gb/s", "1 external display"),
        ("M2 Ultra", "Thunderbolt 4 · 40 Gb/s", "up to 6 external displays"),
        ("M2 Max", "Thunderbolt 4 · 40 Gb/s", "up to 4 external displays"),
        ("M2 Pro", "Thunderbolt 4 · 40 Gb/s", "up to 2 external displays"),
        ("M2", "Thunderbolt 3 / USB4 · 40 Gb/s", "1 external display"),
        ("M3 Max", "Thunderbolt 4 · 40 Gb/s", "up to 4 external displays"),
        ("M3 Pro", "Thunderbolt 4 · 40 Gb/s", "up to 2 external displays"),
        ("M3", "Thunderbolt 3 / USB4 · 40 Gb/s", "up to 2 (1 with lid open)"),
        ("M4 Max", "Thunderbolt 5 · 120 Gb/s", "up to 4 external displays"),
        ("M4 Pro", "Thunderbolt 5 · 120 Gb/s", "up to 2 external displays"),
        ("M4", "Thunderbolt 4 · 40 Gb/s", "up to 2 external displays"),
    ]

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
        if let spec = chipSpecs.first(where: { chip.contains($0.match) }) {
            props["Spec: Thunderbolt"] = .string(spec.thunderbolt)
            props["Spec: Displays"] = .string(spec.displays)
            props["Spec: Source"] = .string("reference table for \(spec.match) — verify against your exact model")
        } else {
            props["Spec: Source"] = .string("no reference entry for this chip — measured values below are live registry data")
        }
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
