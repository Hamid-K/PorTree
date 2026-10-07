import Testing
import Foundation
@testable import PortreeCore

@Suite struct DoctorTests {

    private func diagnose(_ roots: [DeviceNode]) -> Doctor.Report {
        Doctor.diagnose(snapshot: Snapshot(usbRoots: roots, tbRoots: []))
    }

    @Test func throttledDeviceFlagsTheLimitingEdge() {
        // SuperSpeed-revision device (guaranteed 5G-capable) trained at 480M
        // behind a 480M hub: problem on the device, red edge on its link.
        let device = fixture(id: 3, vid: 1, pid: 1, bps: 480_000_000, bcdUSB: 0x0320)
        let hub = fixture(id: 2, deviceClass: 9, bps: 480_000_000, children: [device])
        let report = diagnose([controller(id: 1, children: [hub])])
        let issue = report.byNode[3]?.first { $0.kind == .throttled }
        #expect(issue?.severity == .problem)
        #expect(report.flaggedEdges.contains(3))
    }

    @Test func capableHubOnWeakLinkIsBottleneckWarning() {
        let hub = fixture(id: 2, deviceClass: 9, bps: 480_000_000, bcdUSB: 0x0320)
        let upstream = fixture(id: 4, deviceClass: 9, bps: 480_000_000, children: [hub])
        let report = diagnose([controller(id: 1, children: [upstream])])
        #expect(report.byNode[2]?.contains { $0.kind == .bottleneckHub && $0.severity == .warning } == true)
    }

    @Test func usb2DeviceNeverFlaggedFromBcdAlone() {
        // bcdUSB 2.10 proves nothing about being faster than 12M — honesty
        // rule: stay silent (the old mapping false-flagged every HID device).
        let mouse = fixture(id: 3, vid: 1, pid: 1, bps: 12_000_000, bcdUSB: 0x0210)
        let report = diagnose([controller(id: 1, children: [mouse])])
        #expect(report.byNode[3] == nil)
    }

    @Test func powerBudgetGrading() {
        let heavy = (0..<4).map { fixture(id: 10 + UInt64($0), vid: 1, pid: 1, powerMA: 800) }  // 3200 mA
        let hubOver = fixture(id: 2, deviceClass: 9, bps: 480_000_000, children: heavy)
        let over = diagnose([controller(id: 1, children: [hubOver])])
        #expect(over.byNode[2]?.contains { $0.kind == .powerBudget && $0.severity == .problem } == true)

        let near = (0..<3).map { fixture(id: 20 + UInt64($0), vid: 1, pid: 1, powerMA: 850) }  // 2550 = 85%
        let hubNear = fixture(id: 2, deviceClass: 9, bps: 480_000_000, children: near)
        let warn = diagnose([controller(id: 1, children: [hubNear])])
        #expect(warn.byNode[2]?.contains { $0.kind == .powerNearLimit && $0.severity == .warning } == true)
    }

    @Test func deepChainWarnsEarlyAndErrorsAtLimit() {
        let tier3 = fixture(id: 4, deviceClass: 9, bps: 480_000_000)
        let tier2 = fixture(id: 3, deviceClass: 9, bps: 480_000_000, children: [tier3])
        let tier1 = fixture(id: 2, deviceClass: 9, bps: 480_000_000, children: [tier2])
        let report = diagnose([controller(id: 1, tierLimit: 3, children: [tier1])])
        #expect(report.byNode[3]?.contains { $0.kind == .deepChain && $0.severity == .warning } == true)
        #expect(report.byNode[4]?.contains { $0.kind == .deepChain && $0.severity == .problem } == true)
        #expect(report.byNode[2]?.contains { $0.kind == .deepChain } != true)
    }

    @Test func singleTTContention() {
        let slowA = fixture(id: 3, vid: 1, pid: 1, bps: 12_000_000)
        let slowB = fixture(id: 4, vid: 1, pid: 2, bps: 1_500_000)
        let singleTT = fixture(id: 2, deviceClass: 9, protocolCode: 1, bps: 480_000_000, children: [slowA, slowB])
        let report = diagnose([controller(id: 1, children: [singleTT])])
        #expect(report.byNode[2]?.contains { $0.kind == .ttContention } == true)

        let multiTT = fixture(id: 2, deviceClass: 9, protocolCode: 2, bps: 480_000_000, children: [slowA, slowB])
        #expect(diagnose([controller(id: 1, children: [multiTT])]).byNode[2]?.contains { $0.kind == .ttContention } != true)
    }

    @Test func noFreePorts() {
        let full = fixture(
            id: 2, deviceClass: 9, bps: 480_000_000,
            extra: ["Portree Ports Total": .int(4), "Portree Ports Free": .int(0)]
        )
        let report = diagnose([controller(id: 1, children: [full])])
        #expect(report.byNode[2]?.contains { $0.kind == .noFreePorts } == true)
    }

    @Test func aggregateOversubscriptionGrading() {
        // 20G of leaf demand over a 5G uplink → ratio 4 → warning.
        let leafA = fixture(id: 3, vid: 1, pid: 1, bps: 10_000_000_000)
        let leafB = fixture(id: 4, vid: 1, pid: 2, bps: 10_000_000_000)
        let hub = fixture(id: 2, deviceClass: 9, bps: 5_000_000_000, children: [leafA, leafB])
        let report = diagnose([controller(id: 1, children: [hub])])
        let issue = report.byNode[2]?.first { $0.kind == .bandwidthOversubscribed }
        #expect(issue?.severity == .warning)

        // 6G over 5G → ratio 1.2 → informational only.
        let mild = fixture(id: 2, deviceClass: 9, bps: 5_000_000_000,
                           children: [fixture(id: 3, vid: 1, pid: 1, bps: 5_000_000_000),
                                      fixture(id: 4, vid: 1, pid: 2, bps: 1_000_000_000)])
        let mildIssue = diagnose([controller(id: 1, children: [mild])]).byNode[2]?
            .first { $0.kind == .bandwidthOversubscribed }
        #expect(mildIssue?.severity == .info)
    }

    @Test func overcurrentAndEnumerationCounters() {
        let flaky = fixture(
            id: 3, vid: 1, pid: 1, bps: 480_000_000,
            extra: [
                "Port kPortStatOverCurrentCount": .int(2),
                "Port kPortStatEnumerationFailureCount": .int(5),
            ]
        )
        let report = diagnose([controller(id: 1, children: [flaky])])
        #expect(report.byNode[3]?.contains { $0.kind == .overcurrent && $0.severity == .problem } == true)
        #expect(report.byNode[3]?.contains { $0.kind == .portErrors && $0.severity == .warning } == true)
    }
}

@Suite struct PropertyValueTests {

    @Test func bridgesCoreFoundationTypes() {
        #expect(PropertyValue(cf: "hello" as NSString) == .string("hello"))
        #expect(PropertyValue(cf: NSNumber(value: true)) == .bool(true))
        #expect(PropertyValue(cf: NSNumber(value: 10_000_000_000)) == .int(10_000_000_000))  // no 32-bit truncation
        #expect(PropertyValue(cf: NSNumber(value: 1.5)) == .double(1.5))
        #expect(PropertyValue(cf: Data([1, 2, 3]) as NSData) == .data(Data([1, 2, 3])))
        #expect(PropertyValue(cf: [NSNumber(value: 7)] as NSArray) == .array([.int(7)]))
        if case .dict(let dict)? = PropertyValue(cf: ["k": "v" as NSString] as NSDictionary) {
            #expect(dict["k"] == .string("v"))
        } else {
            Issue.record("dictionary did not bridge")
        }
    }
}
