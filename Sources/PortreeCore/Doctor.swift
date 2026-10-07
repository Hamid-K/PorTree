import Foundation

/// Automated diagnoses over a snapshot — the "doctor" half of the tool.
/// Every rule reads only data already captured in node properties; a rule
/// that cannot prove its inputs stays silent (no guessed findings).
public enum Doctor {

    public struct Issue: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable {
            case throttled, speedCap, powerBudget, deepChain, ttContention
        }
        public enum Severity: String, Sendable {
            case warning, problem
        }
        public var id: String { "\(kind.rawValue)-\(nodeID)" }
        public let kind: Kind
        public let severity: Severity
        public let nodeID: UInt64
        public let title: String
        public let detail: String
    }

    public struct Report: Sendable {
        public let byNode: [UInt64: [Issue]]
        /// Child IDs whose incoming edge should tint red (the limiting link).
        public let flaggedEdges: Set<UInt64>
        public static let empty = Report(byNode: [:], flaggedEdges: [])

        public init(byNode: [UInt64: [Issue]], flaggedEdges: Set<UInt64>) {
            self.byNode = byNode
            self.flaggedEdges = flaggedEdges
        }

        public var all: [Issue] { byNode.values.flatMap { $0 } }
    }

    public static func diagnose(snapshot: Snapshot) -> Report {
        var issues: [Issue] = []
        var flaggedEdges: Set<UInt64> = []

        for controller in snapshot.usbRoots {
            let tierLimit = controller.properties["UsbHostControllerTierLimit"]?.intValue ?? 6

            // Per-receptacle power budget: sum of sink allocations in the
            // subtree vs the 3000 mA port limit.
            for topDevice in controller.children {
                let subtree = topDevice.flattened()
                let totalMA = subtree.compactMap(\.powerSinkMA).reduce(0, +)
                if totalMA > 3000 {
                    issues.append(Issue(
                        kind: .powerBudget,
                        severity: .problem,
                        nodeID: topDevice.id,
                        title: "Power budget oversubscribed",
                        detail: "Devices below request \(totalMA) mA total; the port limit is 3000 mA. Expect brown-outs or disconnects under load."
                    ))
                }
            }

            walk(controller, upstreamMinBps: Int64.max, hubDepth: 0) { node, upstreamMin, hubDepth in
                // Speed capability from bcdUSB (what the device could do).
                let capability = capabilityBps(node)

                if let capability, node.linkSpeedBps > 0, capability > node.linkSpeedBps {
                    if upstreamMin < capability {
                        issues.append(Issue(
                            kind: .throttled,
                            severity: .problem,
                            nodeID: node.id,
                            title: "Throttled by upstream link",
                            detail: "\(node.name) is USB \(Format.speedLabel(bps: capability))-capable but negotiated \(node.speedLabel); an upstream hop tops out at \(Format.speedLabel(bps: upstreamMin)). Move it closer to the Mac or use a faster hub."
                        ))
                        flaggedEdges.insert(node.id)
                    } else {
                        issues.append(Issue(
                            kind: .speedCap,
                            severity: .warning,
                            nodeID: node.id,
                            title: "Below rated speed",
                            detail: "\(node.name) reports \(Format.bcd(node.properties["bcdUSB"]?.intValue ?? 0)) capability (\(Format.speedLabel(bps: capability))) but negotiated \(node.speedLabel). Cable, port, or device-side limit."
                        ))
                    }
                }

                if node.isHub && hubDepth >= tierLimit {
                    issues.append(Issue(
                        kind: .deepChain,
                        severity: .warning,
                        nodeID: node.id,
                        title: "Hub chain at tier limit",
                        detail: "This hub sits at tier \(hubDepth) of \(tierLimit) (UsbHostControllerTierLimit). Devices behind it may fail to enumerate."
                    ))
                }

                // USB2 transaction-translator contention: a single-TT hub
                // (bDeviceProtocol 1) carrying ≥2 low/full-speed devices
                // shares one 12 Mb/s translator among them.
                if node.isHub,
                   node.properties["bDeviceProtocol"]?.intValue == 1,
                   Format.tier(forBps: node.linkSpeedBps) == .usb2 {
                    let slowDescendants = node.flattened().dropFirst().filter { $0.tier == .usb1 }
                    if slowDescendants.count >= 2 {
                        issues.append(Issue(
                            kind: .ttContention,
                            severity: .warning,
                            nodeID: node.id,
                            title: "Single-TT contention",
                            detail: "\(slowDescendants.count) low/full-speed devices share this single-TT hub's one translator (\(slowDescendants.map(\.name).joined(separator: ", ")))."
                        ))
                    }
                }
            }
        }

        var byNode: [UInt64: [Issue]] = [:]
        for issue in issues { byNode[issue.nodeID, default: []].append(issue) }
        return Report(byNode: byNode, flaggedEdges: flaggedEdges)
    }

    /// What the device claims it can do, from bcdUSB. Conservative mapping;
    /// nil when unknown (then no throttle/cap rule fires).
    private static func capabilityBps(_ node: DeviceNode) -> Int64? {
        guard node.kind == .usbDevice, let bcd = node.properties["bcdUSB"]?.intValue else { return nil }
        switch bcd {
        case ..<0x0200: return 12_000_000
        case ..<0x0300: return 480_000_000
        case 0x0300..<0x0310: return 5_000_000_000
        case 0x0310..<0x0320: return 10_000_000_000
        default: return 20_000_000_000
        }
    }

    private static func walk(
        _ node: DeviceNode,
        upstreamMinBps: Int64,
        hubDepth: Int,
        visit: (DeviceNode, Int64, Int) -> Void
    ) {
        for child in node.children {
            let childHubDepth = child.isHub ? hubDepth + 1 : hubDepth
            visit(child, upstreamMinBps, childHubDepth)
            let nextMin = child.linkSpeedBps > 0 ? min(upstreamMinBps, child.linkSpeedBps) : upstreamMinBps
            walk(child, upstreamMinBps: nextMin, hubDepth: childHubDepth, visit: visit)
        }
    }
}
