import Testing
import Foundation
@testable import PortreeCore

@Suite struct TrustStoreTests {

    @Test func learnTrustAndMatch() {
        let store = TrustStore(fileURL: nil)
        #expect(!store.hasBaseline)

        let keyboard = fixture(id: 1, name: "Keyboard", vid: 0x05AC, pid: 0x1234, serial: "S1")
        let mouseNoSerial = fixture(id: 2, name: "Mouse", vid: 0x046D, pid: 0xC077, location: 0x0214_1000)
        let snapshot = Snapshot(usbRoots: [controller(id: 9, children: [keyboard, mouseNoSerial])], tbRoots: [])

        #expect(store.learn(from: snapshot) == 2)
        #expect(store.hasBaseline)
        #expect(store.isKnown(keyboard))

        // A serial-less device moved to another port keeps its trust.
        let moved = fixture(id: 3, name: "Mouse", vid: 0x046D, pid: 0xC077, location: 0x0220_0000)
        #expect(store.isKnown(moved))

        // A serial-less clone of a serial-bearing known device does NOT pass.
        let clone = fixture(id: 4, name: "Keyboard?", vid: 0x05AC, pid: 0x1234, location: 0x0210_0000)
        #expect(!store.isKnown(clone))

        // Never-seen identity is flagged until trusted explicitly.
        let stranger = fixture(id: 5, name: "Stranger", vid: 0xDEAD, pid: 0xBEEF, serial: "Z9")
        #expect(!store.isKnown(stranger))
        #expect(store.trust(stranger))
        #expect(store.isKnown(stranger))
        #expect(!store.trust(stranger))  // idempotent
    }
}
