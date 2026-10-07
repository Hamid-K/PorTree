import Foundation
import CoreGraphics
import PortreeCore

enum LayoutOrientation: String, CaseIterable {
    case leftToRight, topToBottom

    var label: String {
        switch self {
        case .leftToRight: return "Left to right"
        case .topToBottom: return "Top to bottom"
        }
    }

    var symbol: String {
        switch self {
        case .leftToRight: return "arrow.right.square"
        case .topToBottom: return "arrow.down.square"
        }
    }
}

/// Tidy tree layout in two orientations. The System/SoC node is the real
/// root: USB controllers, TB domains, and PCIe roots hang off it via thick
/// "backbone" edges, so everything visibly belongs to one machine.
/// Coordinates are top-left corners in unscaled content space.
struct TreeLayout {
    static let nodeWidth: CGFloat = 232
    static let nodeHeight: CGFloat = 64
    static let gapMain: CGFloat = 72      // along the tree direction
    static let gapCross: CGFloat = 16     // between siblings
    static let sectionGap: CGFloat = 36   // between USB / TB / PCIe groups

    struct Edge: Identifiable {
        let id: String
        let childID: UInt64
        let childKind: NodeKind
        let from: CGPoint
        let to: CGPoint
        let tier: Tier
        let bps: Int64
        let dashed: Bool
        let isBackbone: Bool
        let secondary: Bool   // merged twin's USB2 stub
    }

    private(set) var positions: [UInt64: CGPoint] = [:]
    private(set) var visibleNodes: [DeviceNode] = []
    private(set) var edges: [Edge] = []
    private(set) var size: CGSize = .zero
    let orientation: LayoutOrientation

    init(
        systemRoot: DeviceNode?,
        usbRoots: [DeviceNode],
        tbRoots: [DeviceNode],
        pciRoots: [DeviceNode],
        collapsed: Set<UInt64>,
        orientation: LayoutOrientation
    ) {
        self.orientation = orientation
        let horizontal = orientation == .leftToRight
        // Abstract axes: "main" advances with depth, "cross" stacks siblings.
        let nodeMain: CGFloat = horizontal ? Self.nodeWidth : Self.nodeHeight
        let nodeCross: CGFloat = horizontal ? Self.nodeHeight : Self.nodeWidth
        var cursorCross: CGFloat = 24
        var mainByID: [UInt64: CGFloat] = [:]
        var crossByID: [UInt64: CGFloat] = [:]

        let sectionRoots = usbRoots + tbRoots + pciRoots
        let sectionBreaks: Set<UInt64> = {
            var breaks: Set<UInt64> = []
            if let firstTB = tbRoots.first { breaks.insert(firstTB.id) }
            if let firstPCI = pciRoots.first { breaks.insert(firstPCI.id) }
            return breaks
        }()

        func place(_ node: DeviceNode, depth: Int) {
            let main = 24 + CGFloat(depth) * (nodeMain + Self.gapMain)
            let open = !node.children.isEmpty && !collapsed.contains(node.id)
            if !open {
                mainByID[node.id] = main
                crossByID[node.id] = cursorCross
                cursorCross += nodeCross + Self.gapCross
            } else {
                let start = cursorCross
                for child in node.children {
                    if sectionBreaks.contains(child.id) { cursorCross += Self.sectionGap }
                    place(child, depth: depth + 1)
                }
                let first = crossByID[node.children.first!.id]!
                let last = crossByID[node.children.last!.id]!
                mainByID[node.id] = main
                crossByID[node.id] = max(start, (first + last) / 2)
                cursorCross = max(cursorCross, crossByID[node.id]! + nodeCross + Self.gapCross)
            }
            visibleNodes.append(node)
        }

        // Compose one tree: the System node parents every section root.
        var roots = sectionRoots
        if var system = systemRoot {
            system.children = sectionRoots
            roots = [system]
        }
        for root in roots { place(root, depth: 0) }

        var maxMain: CGFloat = 0
        for (id, main) in mainByID {
            let cross = crossByID[id]!
            positions[id] = horizontal
                ? CGPoint(x: main, y: cross)
                : CGPoint(x: cross, y: main)
            maxMain = max(maxMain, main)
        }
        size = horizontal
            ? CGSize(width: maxMain + Self.nodeWidth + 48, height: cursorCross + 24)
            : CGSize(width: cursorCross + 24, height: maxMain + Self.nodeHeight + 48)

        func anchorOut(_ point: CGPoint) -> CGPoint {
            horizontal
                ? CGPoint(x: point.x + Self.nodeWidth, y: point.y + Self.nodeHeight / 2)
                : CGPoint(x: point.x + Self.nodeWidth / 2, y: point.y + Self.nodeHeight)
        }
        func anchorIn(_ point: CGPoint) -> CGPoint {
            horizontal
                ? CGPoint(x: point.x, y: point.y + Self.nodeHeight / 2)
                : CGPoint(x: point.x + Self.nodeWidth / 2, y: point.y)
        }

        func buildEdges(_ node: DeviceNode) {
            guard !collapsed.contains(node.id), let parentPos = positions[node.id] else { return }
            for child in node.children {
                guard let childPos = positions[child.id] else { continue }
                edges.append(Edge(
                    id: "\(node.id)-\(child.id)",
                    childID: child.id,
                    childKind: child.kind,
                    from: anchorOut(parentPos),
                    to: anchorIn(childPos),
                    tier: child.tier,
                    bps: child.linkSpeedBps,
                    dashed: child.tier == .usb1,
                    isBackbone: node.kind == .system,
                    secondary: child.twin != nil
                ))
                buildEdges(child)
            }
        }
        for root in roots { buildEdges(root) }
    }
}
