import Foundation
import CoreGraphics
import PortreeCore

/// Tidy left→right tree layout: leaves stack vertically, parents center over
/// their visible children. Pure function of (roots, collapsed) — cached by the
/// view per snapshot. Coordinates are top-left corners in unscaled space.
struct TreeLayout {
    static let nodeWidth: CGFloat = 232
    static let nodeHeight: CGFloat = 64
    static let gapX: CGFloat = 72
    static let gapY: CGFloat = 16
    static let sectionGap: CGFloat = 44

    struct Edge: Identifiable {
        let id: String
        let childID: UInt64
        let from: CGPoint      // right-center of parent
        let to: CGPoint        // left-center of child
        let tier: Tier
        let bps: Int64
        let dashed: Bool
        let secondary: (tier: Tier, bps: Int64)?  // merged twin's USB2 stub
    }

    private(set) var positions: [UInt64: CGPoint] = [:]
    private(set) var visibleNodes: [DeviceNode] = []
    private(set) var edges: [Edge] = []
    private(set) var size: CGSize = .zero

    init(usbRoots: [DeviceNode], tbRoots: [DeviceNode], collapsed: Set<UInt64>) {
        var cursorY: CGFloat = 24

        func place(_ node: DeviceNode, depth: Int) {
            let x = 24 + CGFloat(depth) * (Self.nodeWidth + Self.gapX)
            let open = !node.children.isEmpty && !collapsed.contains(node.id)
            if !open {
                positions[node.id] = CGPoint(x: x, y: cursorY)
                cursorY += Self.nodeHeight + Self.gapY
            } else {
                let childStart = cursorY
                for child in node.children { place(child, depth: depth + 1) }
                let first = positions[node.children.first!.id]!.y
                let last = positions[node.children.last!.id]!.y
                let centered = (first + last) / 2
                positions[node.id] = CGPoint(x: x, y: max(childStart, centered))
                cursorY = max(cursorY, positions[node.id]!.y + Self.nodeHeight + Self.gapY)
            }
            visibleNodes.append(node)
        }

        for root in usbRoots { place(root, depth: 0) }
        if !tbRoots.isEmpty {
            cursorY += Self.sectionGap
            for root in tbRoots { place(root, depth: 0) }
        }

        // Edges between visible parent/child pairs.
        func buildEdges(_ node: DeviceNode) {
            guard !collapsed.contains(node.id), let parentPos = positions[node.id] else { return }
            for child in node.children {
                guard let childPos = positions[child.id] else { continue }
                edges.append(Edge(
                    id: "\(node.id)-\(child.id)",
                    childID: child.id,
                    from: CGPoint(x: parentPos.x + Self.nodeWidth, y: parentPos.y + Self.nodeHeight / 2),
                    to: CGPoint(x: childPos.x, y: childPos.y + Self.nodeHeight / 2),
                    tier: child.tier,
                    bps: child.linkSpeedBps,
                    dashed: child.tier == .usb1,
                    secondary: child.twin.map { (Format.tier(forBps: $0.lowSpeedBps), $0.lowSpeedBps) }
                ))
                buildEdges(child)
            }
        }
        for root in usbRoots + tbRoots { buildEdges(root) }

        let maxX = positions.values.map(\.x).max() ?? 0
        size = CGSize(width: maxX + Self.nodeWidth + 48, height: cursorY + 24)
    }
}
