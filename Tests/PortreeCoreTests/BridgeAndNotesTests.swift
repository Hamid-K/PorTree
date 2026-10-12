import Testing
import Foundation
@testable import PortreeCore

@Suite struct BridgeTests {
    private func hidInterface(name: String?, page: Int64, usage: Int64 = 1) -> SubEntry {
        var props: [String: PropertyValue] = [
            "bInterfaceClass": .int(3), "bInterfaceSubClass": .int(0), "bInterfaceProtocol": .int(0),
            "DeviceUsagePairs": .array([.dict(["DeviceUsagePage": .int(page), "DeviceUsage": .int(usage)])]),
        ]
        if let name { props["Portree InterfaceName"] = .string(name) }
        return SubEntry(id: "if-\(name ?? "x")", title: "ifc", detail: "", properties: props)
    }

    /// The live Microchip 0424:7260 shape: vendor-usage HID named "HID I2C".
    @Test func hubControllerBridgeFromInterfaceName() {
        var node = fixture(id: 1, name: "USB2 Controller Hub", vid: 0x0424, pid: 0x7260)
        node.interfaces = [hidInterface(name: "HID I2C", page: 0xFF)]
        let bridge = node.bridgeInfo
        #expect(bridge?.buses == ["I2C"])
        #expect(bridge?.chip == nil)
        #expect(bridge?.label == "I2C bridge (per interface name)")
    }

    @Test func knownChipIsIdentifiedByVidPid() {
        let node = fixture(id: 2, name: "CP2112 HID USB-to-SMBus Bridge", vid: 0x10C4, pid: 0xEA90)
        #expect(node.bridgeInfo?.label == "SMBus/I2C bridge (Silicon Labs CP2112)")
    }

    @Test func standardHIDNamedLikeABusIsNotABridge() {
        // A real keyboard interface whose vendor string happens to say SPI.
        var node = fixture(id: 3, name: "SPI Keyboard", vid: 1, pid: 2)
        node.interfaces = [hidInterface(name: "SPI Keyboard", page: 0x01, usage: 0x06)]
        #expect(node.bridgeInfo == nil)
    }

    @Test func vendorHIDWithoutBusNameIsNotLabeled() {
        var node = fixture(id: 4, name: "RGB Controller", vid: 1, pid: 3)
        node.interfaces = [hidInterface(name: "LED Control", page: 0xFF00)]
        #expect(node.bridgeInfo == nil)
    }

    @Test func busNamesMatchWholeWordsOnly() {
        #expect(BridgeInfo.busNames(in: "USB-to-UART/I²C bridge") == ["I2C", "UART"])
        #expect(BridgeInfo.busNames(in: "SPIFFS storage") == [])
        #expect(BridgeInfo.busNames(in: "smbus host") == ["SMBus"])
    }
}

@Suite struct ReleaseNotesTests {
    @Test func markdownBlocks() {
        let blocks = ReleaseNotes.blocks("""
        Talk to your devices.

        ## Serial console
        - Detected **generically**.
        - One session per port.

        > Versioning note: 1.x line.
        A wrapped paragraph
        that continues here.
        """)
        #expect(blocks == [
            .paragraph("Talk to your devices."),
            .heading("Serial console"),
            .bullet("Detected **generically**."),
            .bullet("One session per port."),
            .quote("Versioning note: 1.x line."),
            .paragraph("A wrapped paragraph that continues here."),
        ])
    }

    @Test func emptyNotesYieldNoBlocks() {
        #expect(ReleaseNotes.blocks("  \n\n ").isEmpty)
    }
}
