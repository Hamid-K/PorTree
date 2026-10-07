import Testing
@testable import PortreeCore

@Suite struct TwinMergeTests {

    @Test func mergesSpeedSplitHubPairWithSharedContainer() {
        let kidHigh = fixture(id: 10, name: "camera", bps: 10_000_000_000)
        let kidLow = fixture(id: 11, name: "keyboard", bps: 12_000_000)
        let usb3 = fixture(id: 1, name: "USB3 Hub", deviceClass: 9, bps: 10_000_000_000, container: "C", children: [kidHigh])
        let usb2 = fixture(id: 2, name: "USB2 Hub", deviceClass: 9, bps: 480_000_000, container: "C", children: [kidLow])

        let merged = USBTopologyBuilder.mergeTwinSiblings([usb3, usb2])

        #expect(merged.count == 1)
        #expect(merged[0].id == 1)                      // high-speed personality is canonical
        #expect(merged[0].twin?.secondaryID == 2)
        #expect(Set(merged[0].children.map(\.id)) == [10, 11])  // union of both personalities
    }

    @Test func refusesMergeWithoutSharedContainerID() {
        let a = fixture(id: 1, deviceClass: 9, bps: 10_000_000_000, container: "A")
        let b = fixture(id: 2, deviceClass: 9, bps: 480_000_000, container: "B")
        #expect(USBTopologyBuilder.mergeTwinSiblings([a, b]).count == 2)
    }

    @Test func refusesMergeWithoutSpeedSplit() {
        // Two distinct 10G hubs sharing a ContainerID must not merge.
        let a = fixture(id: 1, deviceClass: 9, bps: 10_000_000_000, container: "C")
        let b = fixture(id: 2, deviceClass: 9, bps: 10_000_000_000, container: "C")
        #expect(USBTopologyBuilder.mergeTwinSiblings([a, b]).count == 2)
    }

    @Test func refusesMergeOfNonHubs() {
        let a = fixture(id: 1, deviceClass: 0, bps: 10_000_000_000, container: "C")
        let b = fixture(id: 2, deviceClass: 0, bps: 480_000_000, container: "C")
        #expect(USBTopologyBuilder.mergeTwinSiblings([a, b]).count == 2)
    }

    @Test func rePairsNestedTiersAfterUnion() {
        // Each personality carries one tier-2 twin half; the union must pair them.
        let inner3 = fixture(id: 30, deviceClass: 9, bps: 10_000_000_000, container: "T2")
        let inner2 = fixture(id: 31, deviceClass: 9, bps: 480_000_000, container: "T2")
        let usb3 = fixture(id: 1, deviceClass: 9, bps: 10_000_000_000, container: "T1", children: [inner3])
        let usb2 = fixture(id: 2, deviceClass: 9, bps: 480_000_000, container: "T1", children: [inner2])

        let merged = USBTopologyBuilder.mergeTwinSiblings([usb3, usb2])

        #expect(merged.count == 1)
        #expect(merged[0].children.count == 1)
        #expect(merged[0].children[0].id == 30)
        #expect(merged[0].children[0].twin?.secondaryID == 31)
    }

    @Test func nodesAreNeverDroppedOrDuplicated() {
        let nodes = (1...6).map { fixture(id: UInt64($0), deviceClass: 9, bps: 480_000_000, container: "X\($0 % 3)") }
        let merged = USBTopologyBuilder.mergeTwinSiblings(nodes)
        // No speed splits anywhere → everything survives untouched.
        #expect(merged.flatMap { $0.flattened() }.count == 6)
    }
}
