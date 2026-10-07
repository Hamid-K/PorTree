import Testing
import Foundation
@testable import PortreeCore

@Suite struct DiffEngineTests {

    private func snap(_ roots: [DeviceNode]) -> Snapshot {
        Snapshot(usbRoots: roots, tbRoots: [])
    }

    @Test func initialSnapshotProducesNoAnimations() {
        let diff = DiffEngine.diff(old: nil, new: snap([controller(id: 1, children: [fixture(id: 2)])]))
        #expect(diff.addedIDs.isEmpty && diff.removedNodes.isEmpty && diff.reenumerated.isEmpty)
    }

    @Test func classifiesPlainAddAndRemove() {
        let old = snap([controller(id: 1, children: [fixture(id: 2, vid: 1, pid: 1, serial: "A")])])
        let new = snap([controller(id: 1, children: [fixture(id: 3, vid: 9, pid: 9, serial: "B")])])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.addedIDs == [3])
        #expect(diff.removedNodes.map(\.id) == [2])
        #expect(diff.reenumerated.isEmpty)
    }

    @Test func replugCollapsesIntoReenumeration() {
        // Same identity (vid+pid+serial), new registry entry ID.
        let old = snap([controller(id: 1, children: [fixture(id: 2, vid: 5, pid: 6, serial: "S")])])
        let new = snap([controller(id: 1, children: [fixture(id: 7, vid: 5, pid: 6, serial: "S")])])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.addedIDs.isEmpty && diff.removedNodes.isEmpty)
        #expect(diff.reenumerated.count == 1)
        #expect(diff.reenumerated[0].newID == 7)
        #expect(diff.reenumerated[0].confident)
    }

    @Test func serialLessReplugMatchesLowConfidence() {
        let old = snap([controller(id: 1, children: [fixture(id: 2, vid: 5, pid: 6, location: 0x0210_0000)])])
        let new = snap([controller(id: 1, children: [fixture(id: 7, vid: 5, pid: 6, location: 0x0210_0000)])])
        let diff = DiffEngine.diff(old: old, new: new)
        #expect(diff.reenumerated.count == 1)
        #expect(!diff.reenumerated[0].confident)
    }
}

@Suite struct BaselineDiffTests {

    private func snap(_ roots: [DeviceNode]) -> Snapshot {
        Snapshot(usbRoots: roots, tbRoots: [])
    }

    @Test func identityKeyedAcrossDifferentEntryIDs() {
        // Same device, totally different registry IDs (reboot/loaded file).
        let baseline = snap([controller(id: 1, children: [fixture(id: 100, vid: 1, pid: 2, serial: "S", bps: 5_000_000_000)])])
        let current = snap([controller(id: 9, children: [fixture(id: 900, vid: 1, pid: 2, serial: "S", bps: 5_000_000_000)])])
        let diff = BaselineDiff.compare(baseline: baseline, current: current)
        #expect(diff.totalCount == 0)
    }

    @Test func detectsMysteryAddition() {
        let baseline = snap([controller(id: 1, children: [])])
        let current = snap([controller(id: 1, children: [fixture(id: 50, name: "USB Receiver", vid: 0x1234, pid: 1, serial: "X")])])
        let diff = BaselineDiff.compare(baseline: baseline, current: current)
        #expect(diff.addedIDs == [50])
        #expect(diff.removed.isEmpty && diff.changed.isEmpty)
    }

    @Test func detectsSpeedRetrainAsChange() {
        let baseline = snap([controller(id: 1, children: [fixture(id: 2, vid: 1, pid: 2, serial: "S", bps: 10_000_000_000)])])
        let current = snap([controller(id: 1, children: [fixture(id: 3, vid: 1, pid: 2, serial: "S", bps: 480_000_000)])])
        let diff = BaselineDiff.compare(baseline: baseline, current: current)
        #expect(diff.changed.count == 1)
        #expect(diff.changed[0].id == 3)
        #expect(diff.changed[0].changes.contains { $0.contains("speed") })
    }

    @Test func detectsPortMoveAsChange() {
        let baseline = snap([controller(id: 1, children: [fixture(id: 2, vid: 1, pid: 2, serial: "S", location: 0x0210_0000)])])
        let current = snap([controller(id: 1, children: [fixture(id: 3, vid: 1, pid: 2, serial: "S", location: 0x0230_0000)])])
        let diff = BaselineDiff.compare(baseline: baseline, current: current)
        #expect(diff.changed.count == 1)
        #expect(diff.changed[0].changes.contains { $0.contains("moved") })
    }

    @Test func serialSwapShowsAsAddPlusRemove() {
        // Serial is part of the identity key: a device whose serial changed is
        // a different identity — it must surface as added + removed (both
        // visible), never silently matched.
        let baseline = snap([controller(id: 1, children: [fixture(id: 2, vid: 1, pid: 2, serial: "OLD")])])
        let current = snap([controller(id: 1, children: [fixture(id: 3, vid: 1, pid: 2, serial: "NEW")])])
        let diff = BaselineDiff.compare(baseline: baseline, current: current)
        #expect(diff.addedIDs == [3])
        #expect(diff.removed.map(\.id) == [2])
    }

    @Test func roundTripsThroughJSON() throws {
        let original = snap([controller(id: 1, children: [fixture(id: 2, vid: 1, pid: 2, serial: "S", bps: 5_000_000_000)])])
        let data = try Exporters.json(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(Snapshot.self, from: data)
        #expect(BaselineDiff.compare(baseline: loaded, current: original).totalCount == 0)
    }
}
