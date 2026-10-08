import Testing
import Foundation
@testable import PortreeCore

@Suite struct FormatTests {

    @Test func int64SpeedsDoNotTruncate() {
        // String(format: "%d", Int64) silently truncates 10 Gb/s to 32 bits;
        // these go through interpolation-based helpers instead.
        #expect(Format.speedLabel(bps: 10_000_000_000) == "10 Gb/s")
        #expect(Format.speedLabel(bps: 5_000_000_000) == "5 Gb/s")
        #expect(Format.speedLabel(bps: 480_000_000) == "480 Mb/s")
        #expect(Format.speedLabel(bps: 12_000_000) == "12 Mb/s")
        #expect(Format.speedLabel(bps: 1_500_000) == "1.5 Mb/s")
    }

    @Test func tiers() {
        #expect(Format.tier(forBps: 12_000_000) == .usb1)
        #expect(Format.tier(forBps: 480_000_000) == .usb2)
        #expect(Format.tier(forBps: 5_000_000_000) == .usb3)
        #expect(Format.tier(forBps: 10_000_000_000) == .usb3)
        #expect(Format.tier(forBps: 40_000_000_000) == .usb4)
    }

    @Test func dellSignedUID() {
        // The Dell U2725QE's switch UID arrives as a signed CFNumber; identity
        // is the bit pattern.
        #expect(Format.tbUID(-9_185_171_858_847_104_256) == "0x8087B6DC08810300")
    }

    @Test func nvmVersion() {
        // hex(ROM Version) "." EEPROM — (68, 3) → "44.3" (Dell), (37, 1) → "25.1".
        #expect(Format.nvmVersion(rom: 68, eeprom: 3) == "44.3")
        #expect(Format.nvmVersion(rom: 37, eeprom: 1) == "25.1")
    }

    @Test func locationPath() {
        // Keychron Link: 0x02141330 = bus 2, ports 1.4.1.3.3.
        #expect(Format.locationPath(0x0214_1330) == "bus 2 · 1.4.1.3.3")
        #expect(Format.locationPath(0x0010_0000) == "bus 0 · 1")
        #expect(Format.locationPath(0x0000_0000) == "bus 0 · root")
    }

    @Test func bcd() {
        #expect(Format.bcd(0x0320) == "3.20")
        #expect(Format.bcd(0x0210) == "2.10")
    }

    @Test func tbLinkBandwidth() {
        // Lane-port Link Bandwidth is in 0.1 Gb/s units.
        #expect(Format.tbLinkBandwidthLabel(tenthsGbps: 400) == "40 Gb/s")
        #expect(Format.tbLinkBandwidthLabel(tenthsGbps: 1200) == "120 Gb/s")
    }

    @Test func swappedSpeedEnums() {
        // tIOUSBHostConnectionSpeed swaps Full/Low vs the legacy enum.
        #expect(Format.usbSpeedEnumLabel(1).contains("Full"))
        #expect(Format.usbSpeedEnumLabel(2).contains("Low"))
    }
}

@Suite struct VersionCompareTests {
    @Test func semverOrdering() {
        #expect(Format.compareVersions("v1.2.0", "1.2.0") == 0)
        #expect(Format.compareVersions("v1.3.0", "v1.2.9") > 0)
        #expect(Format.compareVersions("1.10.0", "1.9.9") > 0)   // numeric, not lexical
        #expect(Format.compareVersions("0.2.0", "1.2.0") < 0)
        #expect(Format.compareVersions("1.2", "1.2.0") == 0)     // missing patch = 0
        #expect(Format.compareVersions("v2.0.0-beta", "2.0.0") == 0)  // suffix ignored
    }
}
