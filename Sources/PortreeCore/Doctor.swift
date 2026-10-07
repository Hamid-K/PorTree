import Foundation

/// Automated diagnoses over a snapshot — the "doctor" half of the tool.
/// Every rule reads only data already captured in node properties; a rule
/// that cannot prove its inputs stays silent (no guessed findings).
public enum Doctor {

    public struct Issue: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable {
            case throttled, speedCap, bottleneckHub, powerBudget, powerNearLimit
            case overcurrent, portErrors, deepChain, ttContention, tbDowntrain
            case noFreePorts, bandwidthOversubscribed
        }
        public enum Severity: String, Sendable, Comparable {
            case info, warning, problem
            public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
            private var rank: Int {
                switch self { case .info: 0; case .warning: 1; case .problem: 2 }
            }
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
            // subtree vs the 3000 mA port limit — with an early warning band
            // at 80% before the hard oversubscription problem.
            for topDevice in controller.children {
                let subtree = topDevice.flattened()
                let totalMA = subtree.compactMap(\.powerSinkMA).reduce(0, +)
                let limit: Int64 = topDevice.properties["Port kUSBWakePortCurrentLimit"]?.intValue ?? 3000
                if totalMA > limit {
                    issues.append(Issue(
                        kind: .powerBudget,
                        severity: .problem,
                        nodeID: topDevice.id,
                        title: "Power budget oversubscribed",
                        detail: "Devices below request \(totalMA) mA total; the port limit is \(limit) mA. Expect brown-outs or disconnects under load."
                    ))
                } else if totalMA * 5 >= limit * 4 {
                    issues.append(Issue(
                        kind: .powerNearLimit,
                        severity: .warning,
                        nodeID: topDevice.id,
                        title: "Approaching port power limit",
                        detail: "Devices below request \(totalMA) of \(limit) mA (\(totalMA * 100 / limit)%). One more bus-powered device may push the port over."
                    ))
                }
            }

            walk(controller, upstreamMinBps: Int64.max, hubDepth: 0) { node, upstreamMin, hubDepth in
                // Speed capability from bcdUSB (what the device could do).
                let capability = capabilityBps(node)

                if let capability, node.linkSpeedBps > 0, capability > node.linkSpeedBps {
                    if upstreamMin < capability {
                        issues.append(Issue(
                            kind: node.isHub ? .bottleneckHub : .throttled,
                            severity: node.isHub ? .warning : .problem,
                            nodeID: node.id,
                            title: node.isHub ? "Hub bottlenecked by upstream" : "Throttled by upstream link",
                            detail: node.isHub
                                ? "\(node.name) is \(Format.speedLabel(bps: capability))-capable but its upstream path tops out at \(Format.speedLabel(bps: upstreamMin)) — everything behind this hub shares the weaker link."
                                : "\(node.name) is \(Format.speedLabel(bps: capability))-capable but negotiated \(node.speedLabel); an upstream hop tops out at \(Format.speedLabel(bps: upstreamMin)). Move it closer to the Mac or use a faster hub."
                        ))
                        flaggedEdges.insert(node.id)
                    } else {
                        issues.append(Issue(
                            kind: .speedCap,
                            severity: node.isHub ? .info : .warning,
                            nodeID: node.id,
                            title: node.isHub ? "Hub negotiated below capability" : "Below rated speed",
                            detail: "\(node.name) reports \(Format.bcd(node.properties["bcdUSB"]?.intValue ?? 0)) capability (\(Format.speedLabel(bps: capability))) but negotiated \(node.speedLabel). Cable, port, or device-side limit\(node.isHub ? " — a bottleneck for devices behind it" : "")."
                        ))
                    }
                }

                if node.isHub {
                    // Occupancy: all ports taken.
                    if let total = node.properties["Portree Ports Total"]?.intValue, total > 0,
                       node.properties["Portree Ports Free"]?.intValue == 0 {
                        issues.append(Issue(
                            kind: .noFreePorts,
                            severity: .info,
                            nodeID: node.id,
                            title: "No free ports",
                            detail: "All \(total) ports on this hub are occupied."
                        ))
                    }
                    // Aggregate oversubscription: the collective worst case,
                    // complementing (not replacing) per-device throttling.
                    // Computed from negotiated capabilities, never live
                    // traffic — record mode shows actual usage.
                    if node.linkSpeedBps > 0 {
                        let demand = node.flattened().dropFirst()
                            .filter { !$0.isHub && $0.kind == .usbDevice }
                            .map(\.linkSpeedBps)
                            .reduce(0, +)
                        if demand > node.linkSpeedBps {
                            let ratio = Double(demand) / Double(node.linkSpeedBps)
                            issues.append(Issue(
                                kind: .bandwidthOversubscribed,
                                severity: ratio > 2 ? .warning : .info,
                                nodeID: node.id,
                                title: "Uplink bandwidth oversubscribed",
                                detail: "Devices behind this hub can collectively demand \(Format.speedLabel(bps: demand)) over a \(node.speedLabel) uplink (\(String(format: "%.1f", ratio))×). Theoretical worst case from negotiated link speeds — they only contend when active together; record mode shows live usage."
                            ))
                        }
                    }
                }

                // Port error counters from the IOService-plane port object.
                let overcurrent = (node.properties["Port kPortStatOverCurrentCount"]?.intValue ?? 0)
                    + (node.properties["Overcurrent Count"]?.intValue ?? 0)
                if overcurrent > 0 {
                    issues.append(Issue(
                        kind: .overcurrent,
                        severity: .problem,
                        nodeID: node.id,
                        title: "Overcurrent events recorded",
                        detail: "\(overcurrent) overcurrent event\(overcurrent == 1 ? "" : "s") on this port since boot — the device (or its cable) drew more than the port could deliver."
                    ))
                }
                let enumFails = (node.properties["Port kPortStatEnumerationFailureCount"]?.intValue ?? 0)
                    + (node.properties["Port kPortStatAddressFailureCount"]?.intValue ?? 0)
                if enumFails > 0 {
                    issues.append(Issue(
                        kind: .portErrors,
                        severity: .warning,
                        nodeID: node.id,
                        title: "Enumeration failures on this port",
                        detail: "\(enumFails) enumeration/address failure\(enumFails == 1 ? "" : "s") recorded since boot — flaky cable or marginal device."
                    ))
                }
                if let linkErrors = node.properties["Port link-error-count"]?.intValue, linkErrors > 0 {
                    issues.append(Issue(
                        kind: .portErrors,
                        severity: .info,
                        nodeID: node.id,
                        title: "Link errors recorded",
                        detail: "\(linkErrors) SuperSpeed link error\(linkErrors == 1 ? "" : "s") since boot."
                    ))
                }

                if node.isHub {
                    if hubDepth >= tierLimit {
                        issues.append(Issue(
                            kind: .deepChain,
                            severity: .problem,
                            nodeID: node.id,
                            title: "Hub chain at tier limit",
                            detail: "This hub sits at tier \(hubDepth) of \(tierLimit) (UsbHostControllerTierLimit). Devices behind it may fail to enumerate."
                        ))
                    } else if hubDepth == tierLimit - 1 {
                        issues.append(Issue(
                            kind: .deepChain,
                            severity: .warning,
                            nodeID: node.id,
                            title: "Deep hub chain",
                            detail: "Tier \(hubDepth) of \(tierLimit) — one more hub level below this point will hit the controller's tier limit and fail to enumerate."
                        ))
                    }
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

        // Thunderbolt: a TB5-capable port trained at 40/80 Gb/s means the
        // cable or the peer is the limit — exactly the "capable node on a
        // weaker link" case, fabric edition.
        for domain in snapshot.tbRoots {
            for node in domain.flattened() where node.kind == .tbSwitch {
                for port in node.interfaces {
                    guard let supported = port.properties["Supported Link Speed"]?.intValue, supported >= 14,
                          let current = port.properties["Current Link Speed"]?.intValue, current > 0,
                          let bandwidth = port.properties["Link Bandwidth"]?.intValue, bandwidth < 1200
                    else { continue }
                    issues.append(Issue(
                        kind: .tbDowntrain,
                        severity: .warning,
                        nodeID: node.id,
                        title: "TB link trained below capability",
                        detail: "This port supports up to 120 Gb/s but the link trained at \(Format.tbLinkBandwidthLabel(tenthsGbps: bandwidth)) — cable or peer-device limit."
                    ))
                    break
                }
            }
        }

        var byNode: [UInt64: [Issue]] = [:]
        for issue in issues { byNode[issue.nodeID, default: []].append(issue) }
        return Report(byNode: byNode, flaggedEdges: flaggedEdges)
    }

    /// PROVABLE minimum capability. bcdUSB is a spec *revision*, not a speed:
    /// plenty of 5 Gb/s parts report 3.10/3.20, and plenty of 12 Mb/s HID
    /// devices report 2.00 — mapping revisions to their maximum speed fires
    /// false warnings on healthy hardware. The only safe inference is the
    /// floor: a ≥3.0-revision device is guaranteed SuperSpeed-capable
    /// (5 Gb/s). Anything else: stay silent (the file's honesty rule).
    private static func capabilityBps(_ node: DeviceNode) -> Int64? {
        guard node.kind == .usbDevice, let bcd = node.properties["bcdUSB"]?.intValue else { return nil }
        return bcd >= 0x0300 ? 5_000_000_000 : nil
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
