import SwiftUI
import PortreeCore

/// The hierarchy chart: elbow connectors colored by protocol tier and
/// weighted by speed, node cards with class icons, foldable subtrees with
/// "+N" pills, pan (scroll) and zoom (pinch / ⌘±).
struct GraphView: View {
    @Environment(AppStore.self) private var store
    @State private var gestureZoom: CGFloat = 1.0

    var body: some View {
        let layout = TreeLayout(
            usbRoots: store.usbDisplayRoots,
            tbRoots: store.tbDisplayRoots,
            collapsed: store.collapsed
        )
        let zoom = store.zoom * gestureZoom
        let search = store.searchResult

        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    EdgeCanvas(edges: layout.edges, dimmed: search.map { s in
                        Set(layout.edges.filter { !s.visible.contains($0.childID) }.map(\.id))
                    } ?? [])

                    ForEach(layout.visibleNodes) { node in
                        let position = layout.positions[node.id] ?? .zero
                        NodeCard(
                            node: node,
                            collapsedCount: store.collapsed.contains(node.id) ? node.flattened().count - 1 : 0,
                            isSelected: store.selection == node.id,
                            isGhost: store.ghostIDs.contains(node.id),
                            isArrival: store.arrivalIDs.contains(node.id),
                            isReenumerated: store.reenumeratedIDs.contains(node.id),
                            isDimmed: search.map { !$0.visible.contains(node.id) } ?? false,
                            isMatch: search.map { $0.matches.contains(node.id) } ?? false
                        )
                        .frame(width: TreeLayout.nodeWidth, height: TreeLayout.nodeHeight)
                        .position(
                            x: position.x + TreeLayout.nodeWidth / 2,
                            y: position.y + TreeLayout.nodeHeight / 2
                        )
                        .id(node.id)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: layout.size.width * zoom,
                    height: layout.size.height * zoom,
                    alignment: .topLeading
                )
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .gesture(
                MagnifyGesture()
                    .onChanged { value in gestureZoom = value.magnification }
                    .onEnded { value in
                        store.zoom = min(2.0, max(0.25, store.zoom * value.magnification))
                        gestureZoom = 1.0
                    }
            )
            .onChange(of: store.pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                store.pendingScrollTarget = nil
            }
        }
    }
}

private struct EdgeCanvas: View {
    let edges: [TreeLayout.Edge]
    let dimmed: Set<String>

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                let midX = (edge.from.x + edge.to.x) / 2
                var path = Path()
                path.move(to: edge.from)
                path.addCurve(
                    to: edge.to,
                    control1: CGPoint(x: midX, y: edge.from.y),
                    control2: CGPoint(x: midX, y: edge.to.y)
                )
                let opacity = dimmed.contains(edge.id) ? 0.15 : 0.85
                var style = StrokeStyle(lineWidth: Theme.edgeWidth(bps: edge.bps), lineCap: .round)
                if edge.dashed { style.dash = [6, 5] }
                context.stroke(path, with: .color(edge.tier.color.opacity(opacity)), style: style)

                // Merged hub twin: a thin parallel stub for the USB2 personality.
                if let secondary = edge.secondary {
                    var stub = Path()
                    stub.move(to: CGPoint(x: edge.from.x, y: edge.from.y + 5))
                    stub.addCurve(
                        to: CGPoint(x: edge.to.x, y: edge.to.y + 5),
                        control1: CGPoint(x: midX, y: edge.from.y + 5),
                        control2: CGPoint(x: midX, y: edge.to.y + 5)
                    )
                    context.stroke(
                        stub,
                        with: .color(secondary.tier.color.opacity(opacity * 0.7)),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                    )
                }
            }
        }
    }
}

private struct NodeCard: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode
    let collapsedCount: Int
    let isSelected: Bool
    let isGhost: Bool
    let isArrival: Bool
    let isReenumerated: Bool
    let isDimmed: Bool
    let isMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: node.category.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(node.tier.color)
                    .frame(width: 22, height: 22)
                    .background(node.tier.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .strikethrough(isGhost)
                        .lineLimit(1)
                    Text(node.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if !node.children.isEmpty {
                    Button {
                        store.toggleCollapsed(node.id)
                    } label: {
                        Text(collapsedCount > 0 ? "+\(collapsedCount)" : "−")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 4) {
                if !node.speedLabel.isEmpty {
                    CapsuleTag(text: node.speedLabel, color: node.tier.color)
                }
                if isGhost {
                    CapsuleTag(text: "removed", color: .red)
                } else {
                    if node.isTunneled { CapsuleTag(text: "⚡ tunnel", color: .indigo) }
                    if node.twin != nil { CapsuleTag(text: "2 personalities", color: .secondary) }
                    if node.serialNumber != nil { CapsuleTag(text: "serial", color: .secondary) }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: TreeLayout.nodeWidth, height: TreeLayout.nodeHeight, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isReenumerated ? Color.yellow : (isSelected ? Color.accentColor : node.tier.color),
                    lineWidth: isSelected || isReenumerated ? 2 : 1.4
                )
        )
        .shadow(
            color: isArrival ? Color.yellow.opacity(0.8) : (isMatch ? Color.yellow.opacity(0.5) : .clear),
            radius: isArrival ? 10 : (isMatch ? 7 : 0)
        )
        .opacity(isGhost ? 0.45 : (isDimmed ? 0.25 : 1.0))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { store.selection = node.id }
        .contextMenu {
            Button("Copy name") { copy(node.name) }
            if let location = node.locationID {
                Button("Copy location path") { copy(Format.locationPath(location)) }
            }
            if let serial = node.serialNumber {
                Button("Copy serial") { copy(serial) }
            }
        }
        .animation(.easeOut(duration: 0.35), value: isArrival)
        .help(node.name + (node.speedLabel.isEmpty ? "" : " · \(node.speedLabel)"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CapsuleTag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.8))
    }
}
