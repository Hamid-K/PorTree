import Testing
import Foundation
@testable import PortreeCore

@Suite struct EMarkerTests {

    private func data(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Live-captured VDOs from an Apple active USB4 cable (receptacle 3),
    /// decode verified bit-by-bit against USB PD R3.x / Linux pd_vdo.h.
    @Test func activeCableVDODecode() {
        let marker = EMarker(
            vendorID: 0x05AC, productID: 0x7205, bcdDevice: 0x3207,
            productTypeDescription: "Active Cable", productTypeRaw: 4,
            vdos: [
                data(0x2400_05AC),  // ID Header: active cable, Apple
                data(0x0000_0000),  // Cert Stat
                data(0x7205_3207),  // Product VDO
                data(0x4368_F8DB),  // Cable VDO1
                data(0x5A5F_0A01),  // Active Cable VDO2
            ]
        )
        #expect(marker.isActiveCable)
        #expect(!marker.isPassiveCable)
        #expect(marker.ratedCurrent == "5 A")
        #expect(marker.maxVBusVoltage == "20 V")
        #expect(marker.ratedSpeed == "USB4 Gen3 · 40 Gb/s")
        #expect(marker.termination == "both ends active")
        // Active cable → latency class, never a literal length claim.
        // Code 7 spans 60–70 ns per PD R3.x (NOT 70–80 — the table is
        // (N−1)·10..N·10).
        #expect(marker.latencyLabel == "60–70 ns latency class (includes retimer)")
        #expect(marker.construction == "copper · retimer · USB4")
    }

    @Test func passiveCableLatencyIsLengthClass() {
        // Synthetic passive 3A USB 3.2 Gen1 R3.x cable (VDO version 011b),
        // latency code 2 → 10–20 ns ≈ 2 m per the PD table.
        let vdo1: UInt32 = (3 << 21) | (2 << 13) | (1 << 5) | 0b001
        let marker = EMarker(
            vendorID: 0x1234, productID: nil, bcdDevice: nil,
            productTypeDescription: "Passive Cable", productTypeRaw: 3,
            vdos: [data(0x1800_1234), data(0), data(0), data(vdo1)]
        )
        #expect(marker.isPassiveCable)
        #expect(marker.ratedCurrent == "3 A")
        #expect(marker.ratedSpeed == "USB 3.2 Gen1 · 5 Gb/s")
        #expect(marker.latencyLabel == "10–20 ns · ≈2 m class")
        #expect(marker.construction == nil)  // VDO2 is active-cable-only
    }

    @Test func pd2CableNeverFabricatesVoltage() {
        // PD 2.0-era eMarker: VDO version bits are 0, bits 10:9 mean SSTX
        // directionality there — maxVBusVoltage must stay silent and the
        // code-2 speed must say 10 Gb/s, not 20.
        let vdo1: UInt32 = (0b11 << 9) | (1 << 13) | (2 << 5) | 0b010
        let marker = EMarker(
            vendorID: 0x2109, productID: nil, bcdDevice: nil,
            productTypeDescription: "Passive Cable", productTypeRaw: 3,
            vdos: [data(0x1800_2109), data(0), data(0), data(vdo1)]
        )
        #expect(marker.maxVBusVoltage == nil)
        #expect(marker.ratedSpeed == "USB 3.1 Gen2 · 10 Gb/s")
        #expect(marker.ratedCurrent == "5 A")
        #expect(marker.latencyLabel == "<10 ns · ≈1 m class")
    }
}
