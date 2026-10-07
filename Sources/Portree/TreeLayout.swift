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

/// Tidy tree layout in two orientations with PER-NODE HEIGHTS (tag chips wrap
/// into extra lines, so cards grow). The System/SoC node is the real root:
/// USB controllers, TB domains, and PCIe roots hang off it via thick
/// "backbone" edges. Coordinates are top-left corners in unscaled space.
struct TreeLayout {
    static let nodeWidth: CGFloat = 232
    static let nodeHeight: CGFloat = 64      // minimum / single-tag-row height
    static let gapMain: CGFloat = 72
    static let gapCross: CGFloat = 16
    static let sectionGap: CGFloat = 36

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
        let secondary: Bool
        let video: Bool
    }

    private(set) var positions: [UInt64: CGPoint] = [:]
    private(set) var heights: [UInt64: CGFloat] = [:]
    private(set) var visibleNodes: [DeviceNode] = []
    private(set) var edges: [Edge] = []
    private(set) var size: CGSize = .zero
    let orientation: LayoutOrientation

    func height(of id: UInt64) -> CGFloat {
        heights[id] ?? Self.nodeHeight
    }

    init(
        systemRoot: DeviceNode?,
        usbRoots: [DeviceNode],
        tbRoots: [DeviceNode],
        pciRoots: [DeviceNode],
        collapsed: Set<UInt64>,
        orientation: LayoutOrientation,
        nodeHeights: [UInt64: CGFloat] = [:]
    ) {
        self.orientation = orientation
        let horizontal = orientation == .leftToRight

        // Compose one tree: the System node parents every section root.
        let sectionRoots = usbRoots + tbRoots + pciRoots
        var roots = sectionRoots
        if var system = systemRoot {
            system.children = sectionRoots
            roots = [system]
        }
        let sectionBreaks: Set<UInt64> = {
            var breaks: Set<UInt64> = []
            if let firstTB = tbRoots.first { breaks.insert(firstTB.id) }
            if let firstPCI = pciRoots.first { breaks.insert(firstPCI.id) }
            return breaks
        }()

        func h(_ node: DeviceNode) -> CGFloat {
            max(Self.nodeHeight, nodeHeights[node.id] ?? Self.nodeHeight)
        }

        // Pass 1 (top-down only): column offsets from the tallest card at
        // each depth, so variable heights keep depth columns aligned.
        var mainOffset: [Int: CGFloat] = [:]
        if !horizontal {
            var maxAtDepth: [Int: CGFloat] = [:]
            func measure(_ node: DeviceNode, depth: Int) {
                maxAtDepth[depth] = max(maxAtDepth[depth] ?? 0, h(node))
                guard !collapsed.contains(node.id) else { return }
                for child in node.children { measure(child, depth: depth + 1) }
            }
            for root in roots { measure(root, depth: 0) }
            var cursor: CGFloat = 24
            for depth in 0...(maxAtDepth.keys.max() ?? 0) {
                mainOffset[depth] = cursor
                cursor += (maxAtDepth[depth] ?? Self.nodeHeight) + Self.gapMain
            }
        }

        var cursorCross: CGFloat = 24
        var mainByID: [UInt64: CGFloat] = [:]
        var crossByID: [UInt64: CGFloat] = [:]

        func place(_ node: DeviceNode, depth: Int) {
            let main = horizontal
                ? 24 + CGFloat(depth) * (Self.nodeWidth + Self.gapMain)
                : (mainOffset[depth] ?? 24)
            let cross: CGFloat = horizontal ? h(node) : Self.nodeWidth
            let open = !node.children.isEmpty && !collapsed.contains(node.id)
            if !open {
                mainByID[node.id] = main
                crossByID[node.id] = cursorCross
                cursorCross += cross + Self.gapCross
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
                cursorCross = max(cursorCross, crossByID[node.id]! + cross + Self.gapCross)
            }
            heights[node.id] = h(node)
            visibleNodes.append(node)
        }
        for root in roots { place(root, depth: 0) }

        var maxMainExtent: CGFloat = 0
        for (id, main) in mainByID {
            let cross = crossByID[id]!
            positions[id] = horizontal
                ? CGPoint(x: main, y: cross)
                : CGPoint(x: cross, y: main)
            maxMainExtent = max(maxMainExtent, main + (horizontal ? Self.nodeWidth : height(of: id)))
        }
        size = horizontal
            ? CGSize(width: maxMainExtent + 48, height: cursorCross + 24)
            : CGSize(width: cursorCross + 24, height: maxMainExtent + 48)

        func anchorOut(_ id: UInt64) -> CGPoint {
            let point = positions[id]!
            return horizontal
                ? CGPoint(x: point.x + Self.nodeWidth, y: point.y + height(of: id) / 2)
                : CGPoint(x: point.x + Self.nodeWidth / 2, y: point.y + height(of: id))
        }
        func anchorIn(_ id: UInt64) -> CGPoint {
            let point = positions[id]!
            return horizontal
                ? CGPoint(x: point.x, y: point.y + height(of: id) / 2)
                : CGPoint(x: point.x + Self.nodeWidth / 2, y: point.y)
        }

        func buildEdges(_ node: DeviceNode) {
            guard !collapsed.contains(node.id), positions[node.id] != nil else { return }
            for child in node.children {
                guard positions[child.id] != nil else { continue }
                edges.append(Edge(
                    id: "\(node.id)-\(child.id)",
                    childID: child.id,
                    childKind: child.kind,
                    from: anchorOut(node.id),
                    to: anchorIn(child.id),
                    tier: child.tier,
                    bps: child.linkSpeedBps,
                    dashed: child.tier == .usb1,
                    isBackbone: node.kind == .system,
                    secondary: child.twin != nil,
                    video: child.carriesVideo
                ))
                buildEdges(child)
            }
        }
        for root in roots { buildEdges(root) }
    }
}
