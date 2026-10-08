import Foundation

/// Privacy redaction for exports: returns a copy of a snapshot with every
/// identity-bearing value replaced by a RANDOM value of the same shape —
/// consistently within one pass (the same original always maps to the same
/// replacement, so topology relationships stay intact). Model identifiers
/// (vid:pid, device names, speeds) are NOT touched: they identify the
/// product, not the user's unit.
///
/// Randomized: USB serial strings, Thunderbolt UIDs, container IDs, EDID
/// serial numbers, and raw EDID blobs (which embed the serial).
public struct Redactor {

    private var strings: [String: String] = [:]
    private var numbers: [Int64: Int64] = [:]
    private var rng = SystemRandomNumberGenerator()

    public init() {}

    private static let stringKeys: Set<String> = [
        "USB Serial Number", "kUSBSerialNumberString", "Serial Number",
        "kUSBContainerID", "ContainerID", "UsbContainerID",
    ]
    private static let numberKeys: Set<String> = [
        "UID", "SerialNumber",
    ]
    private static let dataKeys: Set<String> = [
        "EDID",
    ]

    private mutating func randomString(like original: String) -> String {
        if let existing = strings[original] { return existing }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")
        let replacement = String(original.map { character in
            character.isLetter || character.isNumber ? alphabet.randomElement(using: &rng)! : character
        })
        strings[original] = replacement
        return replacement
    }

    private mutating func randomNumber(like original: Int64) -> Int64 {
        if let existing = numbers[original] { return existing }
        let replacement = Int64(bitPattern: UInt64.random(in: 1...UInt64.max >> 1, using: &rng))
        numbers[original] = replacement
        return replacement
    }

    private mutating func redact(_ properties: [String: PropertyValue]) -> [String: PropertyValue] {
        var out = properties
        for (key, value) in properties {
            if Self.stringKeys.contains(key), let s = value.stringValue {
                out[key] = .string(randomString(like: s))
            } else if Self.numberKeys.contains(key), let i = value.intValue {
                out[key] = .int(randomNumber(like: i))
            } else if Self.dataKeys.contains(key), let d = value.dataValue {
                var noise = Data(count: d.count)
                for i in 0..<noise.count { noise[i] = UInt8.random(in: 0...255, using: &rng) }
                out[key] = .data(noise)
            } else if key == "Metadata", let dict = value.dictValue {
                out[key] = .dict(redact(dict))
            }
        }
        return out
    }

    private mutating func redact(_ node: DeviceNode) -> DeviceNode {
        DeviceNode(
            id: node.id,
            kind: node.kind,
            name: node.name,
            subtitle: node.subtitle,
            className: node.className,
            category: node.category,
            tier: node.tier,
            speedLabel: node.speedLabel,
            linkSpeedBps: node.linkSpeedBps,
            properties: redact(node.properties),
            interfaces: node.interfaces.map {
                SubEntry(id: $0.id, title: $0.title, detail: $0.detail, properties: redact($0.properties))
            },
            children: node.children.map { redact($0) },
            twin: node.twin,
            crossLinkID: node.crossLinkID
        )
    }

    private mutating func redact(_ sink: DisplaySink) -> DisplaySink {
        DisplaySink(
            registryID: sink.registryID,
            name: sink.name,
            edidProductID: sink.edidProductID,
            edidSerial: sink.edidSerial.map { randomNumber(like: $0) },
            linkRate: sink.linkRate,
            laneCount: sink.laneCount,
            downstreamType: sink.downstreamType,
            tunneled: sink.tunneled,
            receptacle: sink.receptacle,
            active: sink.active,
            properties: redact(sink.properties)
        )
    }

    private mutating func redact(_ link: PortLink) -> PortLink {
        PortLink(
            portType: link.portType,
            portNumber: link.portNumber,
            active: link.active,
            partner: link.partner,
            eMarker: link.eMarker,
            // Same mapping as the switch nodes' UID — the cable→first-hop
            // join must survive redaction.
            cioUID: link.cioUID.map { UInt64(bitPattern: randomNumber(like: Int64(bitPattern: $0))) },
            cableGeneration: link.cableGeneration,
            cableSpeed: link.cableSpeed,
            powerContract: link.powerContract
        )
    }

    public mutating func redact(_ snapshot: Snapshot) -> Snapshot {
        Snapshot(
            usbRoots: snapshot.usbRoots.map { redact($0) },
            tbRoots: snapshot.tbRoots.map { redact($0) },
            pciRoots: snapshot.pciRoots.map { redact($0) },
            systemNode: snapshot.systemNode.map { redact($0) },
            displaySinks: snapshot.displaySinks.map { redact($0) },
            portLinks: snapshot.portLinks.map { redact($0) },
            power: snapshot.power,
            redacted: true,
            takenAt: snapshot.takenAt
        )
    }
}

extension Snapshot {
    /// A privacy-safe copy for sharing: identity values randomized, shape
    /// and topology preserved. See `Redactor`.
    public func redactedCopy() -> Snapshot {
        var redactor = Redactor()
        return redactor.redact(self)
    }
}
