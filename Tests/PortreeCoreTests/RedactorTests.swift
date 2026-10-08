import Testing
import Foundation
@testable import PortreeCore

@Suite struct RedactorTests {

    @Test func redactionMasksIdentityAndPreservesShape() {
        var device = fixture(id: 1, name: "Keyboard", vid: 0x05AC, pid: 0x1234, serial: "C02XYZ123")
        device.interfaces = [SubEntry(id: "i0", title: "if", detail: "", properties: [
            "USB Serial Number": .string("C02XYZ123"),
        ])]
        var tbSwitch = fixture(id: 2, name: "Dock", kind: .tbSwitch)
        tbSwitch = DeviceNode(
            id: tbSwitch.id, kind: .tbSwitch, name: tbSwitch.name, subtitle: "", className: "TB",
            category: .dock, tier: .thunderbolt, speedLabel: "40 Gb/s", linkSpeedBps: 0,
            properties: ["UID": .int(0x1122_3344_5566)], children: [device]
        )
        let sink = DisplaySink(
            registryID: 9, name: "DELL U3223QE", edidProductID: 17010, edidSerial: 892_417_612,
            linkRate: "HBR2", laneCount: 4, downstreamType: "DP", tunneled: true,
            receptacle: 3, active: true,
            properties: ["EDID": .data(Data([1, 2, 3, 4])), "SerialNumber": .int(892_417_612)]
        )
        let snapshot = Snapshot(usbRoots: [], tbRoots: [tbSwitch], displaySinks: [sink])

        let redacted = snapshot.redactedCopy()
        let newSwitch = redacted.tbRoots[0]
        let newDevice = newSwitch.children[0]
        let newSink = redacted.displaySinks[0]

        // Identity values changed…
        #expect(newDevice.serialNumber != "C02XYZ123")
        #expect(newSwitch.properties["UID"]?.intValue != 0x1122_3344_5566)
        #expect(newSink.edidSerial != 892_417_612)
        #expect(newSink.properties["EDID"]?.dataValue != Data([1, 2, 3, 4]))
        // …consistently: device + interface serial map to the SAME mask,
        // sink serial int matches its properties mirror.
        #expect(newDevice.serialNumber == newDevice.interfaces[0].properties["USB Serial Number"]?.stringValue)
        #expect(newSink.edidSerial == newSink.properties["SerialNumber"]?.intValue)
        // Shape preserved: same string length, model identity untouched.
        #expect(newDevice.serialNumber?.count == 9)
        #expect(newDevice.vendorID == 0x05AC && newDevice.productID == 0x1234)
        #expect(newDevice.name == "Keyboard" && newSink.name == "DELL U3223QE")
        #expect(newSink.edidProductID == 17010)
        #expect(newSwitch.id == 2 && newDevice.id == 1)
    }
}

@Suite struct RedactedFlagTests {
    @Test func redactedFlagRoundTrips() throws {
        let snapshot = Snapshot(usbRoots: [], tbRoots: [])
        #expect(!snapshot.redacted)
        let masked = snapshot.redactedCopy()
        #expect(masked.redacted)
        let decoded = try Exporters.decodeSnapshot(Exporters.json(masked))
        #expect(decoded.redacted)
        // Old files without the key decode as not-redacted.
        let legacy = try Exporters.decodeSnapshot(Data("{\"usbRoots\":[],\"tbRoots\":[]}".utf8))
        #expect(!legacy.redacted)
    }
}
