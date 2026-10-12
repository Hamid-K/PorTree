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

    @Test func ft260BusesFollowItsEnabledFunctions() {
        let both = { () -> DeviceNode in
            var n = fixture(id: 5, name: "FT260", vid: 0x0403, pid: 0x6030)
            n.interfaces = [self.hidInterface(name: nil, page: 0xFF00), self.hidInterface(name: nil, page: 0xFF00)]
            return n
        }()
        #expect(both.bridgeInfo?.label == "I2C/UART bridge (FTDI FT260)")
        var single = fixture(id: 6, name: "FT260", vid: 0x0403, pid: 0x6030)
        single.interfaces = [hidInterface(name: nil, page: 0xFF00)]
        #expect(single.bridgeInfo?.label == "I2C or UART bridge (FTDI FT260, one function set by pins)")
    }

    @Test func compactLabelKeepsTheEvidence() {
        var byName = fixture(id: 7, name: "USB2 Controller Hub", vid: 0x0424, pid: 0x7260)
        byName.interfaces = [hidInterface(name: "HID I2C", page: 0xFF)]
        #expect(byName.bridgeInfo?.compactLabel == "I2C bridge · by name")
        let chip = fixture(id: 8, name: "CP2112", vid: 0x10C4, pid: 0xEA90)
        #expect(chip.bridgeInfo?.compactLabel == "SMBus/I2C bridge")
    }

    @Test func vendorClassUARTInterfaceIsLabeledByName() {
        // FTDI FT232R shape: class FF interface named "FT232R USB UART".
        var node = fixture(id: 9, name: "FT232R USB UART", vid: 0x0403, pid: 0x6001)
        node.interfaces = [SubEntry(id: "i0", title: "ifc", detail: "", properties: [
            "bInterfaceClass": .int(0xFF), "Portree InterfaceName": .string("FT232R USB UART"),
        ])]
        #expect(node.bridgeInfo?.label == "UART bridge (per interface name)")
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

    @Test func blankLineSeparatesParagraphs() {
        // The v1.3.1 notes shape: two paragraphs that must stay apart.
        let blocks = ReleaseNotes.blocks("Patch release: fixed the HUD.\n\nIf you're on 1.3.0, update in-app.")
        #expect(blocks == [.paragraph("Patch release: fixed the HUD."), .paragraph("If you're on 1.3.0, update in-app.")])
    }

    @Test func crlfNotesParseLikeLF() {
        let blocks = ReleaseNotes.blocks("## Title\r\n- one\r\n- two\r\n")
        #expect(blocks == [.heading("Title"), .bullet("one"), .bullet("two")])
    }

    @Test func emptyNotesYieldNoBlocks() {
        #expect(ReleaseNotes.blocks("  \n\n ").isEmpty)
    }
}

@Suite struct DeviceTypeTests {
    private func iface(_ cls: Int64, _ sub: Int64 = 0, _ proto: Int64 = 0, name: String? = nil, page: Int64? = nil, usage: Int64 = 1) -> SubEntry {
        var props: [String: PropertyValue] = [
            "bInterfaceClass": .int(cls), "bInterfaceSubClass": .int(sub), "bInterfaceProtocol": .int(proto),
        ]
        if let name { props["Portree InterfaceName"] = .string(name) }
        if let page { props["DeviceUsagePairs"] = .array([.dict(["DeviceUsagePage": .int(page), "DeviceUsage": .int(usage)])]) }
        return SubEntry(id: "if-\(cls)-\(name ?? "")", title: "ifc", detail: "", properties: props)
    }

    @Test func bridgeBecomesItsOwnTypeOnlyWhenNothingMoreSpecificApplies() {
        let bridge = BridgeInfo(buses: ["I2C"], chip: nil)
        #expect(BridgeInfo.category(for: .controller, bridge: bridge) == .bridge)
        #expect(BridgeInfo.category(for: .vendor, bridge: bridge) == .bridge)
        #expect(BridgeInfo.category(for: .hid, bridge: bridge) == .hid)       // a keyboard stays a keyboard
        #expect(BridgeInfo.category(for: .serial, bridge: bridge) == .serial) // console wins
        #expect(BridgeInfo.category(for: .controller, bridge: nil) == .controller)
    }

    @Test func hubControllerBridgeHasNoExtraTypes() {
        var node = fixture(id: 1, name: "USB2 Controller Hub", vid: 0x0424, pid: 0x7260)
        node.interfaces = [iface(0xFF, 0xFF, 0xFF), iface(3, name: "HID I2C", page: 0xFF)]
        #expect(node.additionalCategories(primary: .bridge, hasSerialPort: false).isEmpty)
    }

    @Test func badUSBCompositeShowsTheKeyboardBadge() {
        var stick = fixture(id: 2, name: "Flash Drive", vid: 1, pid: 2)
        stick.interfaces = [iface(8, 6, 0x50), iface(3, 1, 1)]
        #expect(stick.additionalCategories(primary: .storage, hasSerialPort: false) == [.hid])
    }

    @Test func serialBridgeShowsTheBridgeBadge() {
        // MCP2221 shape: CDC serial + vendor HID; main type serial.
        var node = fixture(id: 3, name: "MCP2221 USB-I2C/UART Combo", vid: 0x04D8, pid: 0x00DD)
        node.interfaces = [iface(2, 2, 1), iface(0x0A), iface(3, page: 0xFF00)]
        #expect(node.additionalCategories(primary: .serial, hasSerialPort: true) == [.bridge])
    }

    @Test func extrasAreCappedAtThree() {
        var node = fixture(id: 4, name: "Everything Device", vid: 5, pid: 6)
        node.interfaces = [iface(3, 1, 1), iface(8), iface(1), iface(0x0E), iface(0xE0)]
        #expect(node.additionalCategories(primary: .hub, hasSerialPort: true).count == 3)
    }
}
