import Foundation

/// Classification of a snapshot transition, used for arrival glows, removal
/// ghosts, and the "re-enumerated" collapse (a replug is terminate+publish
/// with a NEW entry ID — the most common flaky-cable signature must render as
/// one re-enumeration, not a ghost plus a new device).
public struct SnapshotDiff: Sendable {
    public struct Reenumeration: Sendable {
        public let oldNode: DeviceNode
        public let newID: UInt64
        public let confident: Bool
    }

    public let addedIDs: Set<UInt64>
    public let removedNodes: [DeviceNode]
    public let reenumerated: [Reenumeration]

    public static let empty = SnapshotDiff(addedIDs: [], removedNodes: [], reenumerated: [])
}

public enum DiffEngine {

    public static func diff(old: Snapshot?, new: Snapshot) -> SnapshotDiff {
        guard let old else { return .empty }  // initial population: no animations
        let oldAll = old.allByID()
        let newAll = new.allByID()

        var added = Set(newAll.keys).subtracting(oldAll.keys)
        var removed = Set(oldAll.keys).subtracting(newAll.keys)
        var reenumerated: [SnapshotDiff.Reenumeration] = []

        for removedID in removed {
            guard let oldNode = oldAll[removedID],
                  let oldIdentity = oldNode.deviceIdentity else { continue }
            if let match = added.first(where: { newAll[$0]?.deviceIdentity?.key == oldIdentity.key }) {
                reenumerated.append(.init(oldNode: oldNode, newID: match, confident: oldIdentity.confident))
                added.remove(match)
                removed.remove(removedID)
            }
        }

        // Only surface real devices (controllers/domains appearing is boot noise).
        let removedNodes = removed.compactMap { oldAll[$0] }
            .filter { $0.kind == .usbDevice || $0.kind == .tbSwitch }
        let addedDevices = added.filter {
            let kind = newAll[$0]?.kind
            return kind == .usbDevice || kind == .tbSwitch
        }

        return SnapshotDiff(addedIDs: addedDevices, removedNodes: removedNodes, reenumerated: reenumerated)
    }
}
