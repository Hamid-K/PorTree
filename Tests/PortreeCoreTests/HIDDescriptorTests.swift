import Testing
import Foundation
@testable import PortreeCore

@Suite struct HIDDescriptorTests {
    private func hex(_ s: String) -> Data {
        var data = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            data.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// Captured live from this Mac's registry: a consumer-control function
    /// (play/pause, volume) — 3 data bits + 5 padding bits, no report ID.
    @Test func consumerControlDescriptor() {
        let d = HIDDescriptor(hex("050c0901a101050c09cd09ea09e91500250195037501810295058105c0"))
        #expect(!d.vendorDefined)
        #expect(d.reports.count == 1)
        #expect(d.reports[0].reportID == 0 && d.reports[0].inputBits == 8)
        #expect(d.lines.contains { $0.text == "Usage (Play/Pause)" })
        #expect(d.lines.contains { $0.text == "Collection (Application)" && $0.depth == 0 })
        #expect(d.lines.last?.text == "End Collection")
    }

    /// Vendor-defined bridge shape: page 0xFF00, 64-byte in/out reports.
    @Test func vendorBridgeDescriptor() {
        let d = HIDDescriptor(hex("0600ff0901a101150026ff0075089540810295409102c0"))
        #expect(d.vendorDefined)
        #expect(d.reports[0].inputBits == 512 && d.reports[0].outputBits == 512)
        #expect(d.lines.first?.text == "Usage Page (Vendor-defined 0xFF00)")
    }

    @Test func truncatedDescriptorDoesNotCrash() {
        let d = HIDDescriptor(Data([0x05, 0x01, 0x26]))  // Logical Max missing its 2 data bytes
        #expect(d.lines.last?.text.contains("truncated") == true)
    }
}
