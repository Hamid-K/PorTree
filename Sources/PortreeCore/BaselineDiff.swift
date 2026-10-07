import Foundation

/// Snapshot-vs-baseline comparison for diagnostics: freeze (or load) a known
/// state, then see exactly what appeared, vanished, or changed. Keyed on
/// device identity (VID+PID+serial / TB UID — see DeviceNode.deviceIdentity),
/// NOT registry entry IDs, so a baseline loaded from a JSON file taken weeks
/// ago compares correctly against live state.
public struct BaselineDiff: Sendable {

    public struct Change: Sendable, Identifiable {
        public let id: UInt64          // current snapshot's node id (jumpable)
        public let name: String
        public let changes: [String]
    }

    /// Current-snapshot IDs not present in the baseline — the "mystery
    /// device" set.
    public let addedIDs: Set<UInt64>
    /// Baseline nodes with no identity match in the current snapshot.
    public let removed: [DeviceNode]
    /// Same identity, different facts (speed, position, name, serial).
    public let changed: [Change]
    public let baselineDate: Date

    public var totalCount: Int { addedIDs.count + removed.count + changed.count }

    public static func compare(baseline: Snapshot, current: Snapshot) -> BaselineDiff {
        let baselineByIdentity = identityMap(baseline)
        let currentByIdentity = identityMap(current)

        var addedIDs: Set<UInt64> = []
        var changed: [Change] = []

        for (key, node) in currentByIdentity {
            guard let old = baselineByIdentity[key] else {
                addedIDs.insert(node.id)
                continue
            }
            var diffs: [String] = []
            if old.speedLabel != node.speedLabel, !old.speedLabel.isEmpty || !node.speedLabel.isEmpty {
                diffs.append("speed \(old.speedLabel.isEmpty ? "—" : old.speedLabel) → \(node.speedLabel.isEmpty ? "—" : node.speedLabel)")
            }
            let oldLocation = old.locationID.map(Format.locationPath)
            let newLocation = node.locationID.map(Format.locationPath)
            if oldLocation != newLocation, let oldLocation, let newLocation {
                diffs.append("moved \(oldLocation) → \(newLocation)")
            }
            if old.name != node.name {
                diffs.append("name \"\(old.name)\" → \"\(node.name)\"")
            }
            if old.serialNumber != node.serialNumber {
                diffs.append("serial changed — descriptor drift is a classic BadUSB signal")
            }
            if old.interfaces.count != node.interfaces.count {
                diffs.append("interfaces \(old.interfaces.count) → \(node.interfaces.count)")
            }
            if !diffs.isEmpty {
                changed.append(Change(id: node.id, name: node.name, changes: diffs))
            }
        }

        let removed = baselineByIdentity
            .filter { currentByIdentity[$0.key] == nil }
            .map(\.value)
            .sorted { $0.name < $1.name }

        return BaselineDiff(
            addedIDs: addedIDs,
            removed: removed,
            changed: changed.sorted { $0.name < $1.name },
            baselineDate: baseline.takenAt
        )
    }

    /// Only nodes with a usable identity take part; infrastructure
    /// (controllers, domains, the System node) is topology, not devices.
    private static func identityMap(_ snapshot: Snapshot) -> [String: DeviceNode] {
        var map: [String: DeviceNode] = [:]
        for root in snapshot.allRoots {
            for node in root.flattened() where node.kind == .usbDevice || node.kind == .tbSwitch || node.kind == .pciDevice {
                guard let identity = node.deviceIdentity else { continue }
                if map[identity.key] == nil { map[identity.key] = node }
            }
        }
        return map
    }
}
