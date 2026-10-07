import SwiftUI
import AppKit
import PortreeCore

/// The hierarchy chart. Interaction model:
///  - drag anywhere to pan; two-finger scroll pans too
///  - pinch, ⌘+scroll-wheel, or toolbar/⌘± to zoom (anchored at the cursor)
///  - click a card to select; the +N pill folds a subtree
/// The System/SoC card is the root; backbone links fan out to USB / TB / PCIe.
struct GraphView: View {
    @Environment(AppStore.self) private var store
    @State private var dragStart: CGSize?
    @State private var gestureZoom: CGFloat = 1.0

    @ViewBuilder
    private func graphContent(layout: TreeLayout, search: (matches: Set<UInt64>, visible: Set<UInt64>)?) -> some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isRecording)) { timeline in
                EdgeCanvas(
                    edges: layout.edges,
                    horizontal: layout.orientation == .leftToRight,
                    dimmed: search.map { s in
                        Set(layout.edges.filter { !s.visible.contains($0.childID) }.map(\.id))
                    } ?? [],
                    flagged: store.issues.flaggedEdges,
                    flow: store.isRecording ? store.rates : [:],
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    zoom: store.zoom,
                    background: store.canvasBackground
                )
            }

            ForEach(layout.visibleNodes) { node in
                let position = layout.positions[node.id] ?? .zero
                let cardHeight = layout.height(of: node.id)
                NodeCard(
                    node: node,
                    height: cardHeight,
                    collapsedCount: store.collapsed.contains(node.id) ? node.flattened().count - 1 : 0,
                    isSelected: store.selection == node.id,
                    isGhost: store.ghostIDs.contains(node.id),
                    isArrival: store.arrivalIDs.contains(node.id),
                    isReenumerated: store.reenumeratedIDs.contains(node.id),
                    isDimmed: search.map { !$0.visible.contains(node.id) } ?? false,
                    isMatch: search.map { $0.matches.contains(node.id) } ?? false
                )
                .frame(width: TreeLayout.nodeWidth, height: cardHeight)
                .position(
                    x: position.x + TreeLayout.nodeWidth / 2,
                    y: position.y + cardHeight / 2
                )
            }
        }
    }

    var body: some View {
        let layout = TreeLayout(
            systemRoot: store.systemDisplayNode,
            usbRoots: store.usbDisplayRoots,
            tbRoots: store.tbDisplayRoots,
            pciRoots: store.pciDisplayRoots,
            collapsed: store.collapsed,
            orientation: store.orientation,
            nodeHeights: TagMetrics.nodeHeights(store: store)
        )
        let search = store.searchResult

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                store.canvasBackground.color

                graphContent(layout: layout, search: search)
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    .scaleEffect(store.zoom * gestureZoom, anchor: .topLeading)
                    .offset(store.panOffset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragStart == nil { dragStart = store.panOffset }
                        store.panOffset = CGSize(
                            width: (dragStart?.width ?? 0) + value.translation.width,
                            height: (dragStart?.height ?? 0) + value.translation.height
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in gestureZoom = value.magnification }  // live preview
                    .onEnded { value in
                        gestureZoom = 1.0
                        store.zoomAround(factor: value.magnification)
                    }
            )
            .background(
                ScrollWheelCatcher { event in
                    if event.command {
                        store.zoomAround(factor: event.deltaY > 0 ? 1.06 : 0.94, anchor: event.location)
                    } else {
                        store.panOffset.width += event.deltaX
                        store.panOffset.height += event.deltaY
                    }
                }
            )
            .onAppear {
                store.lastViewport = geo.size
                if store.panOffset == CGSize(width: 24, height: 24) {
                    store.fitGraph(contentSize: layout.size)
                }
            }
            .onChange(of: geo.size) { _, newSize in store.lastViewport = newSize }
            .onChange(of: store.pendingScrollTarget) { _, target in
                guard let target, let position = layout.positions[target] else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    store.centerGraph(on: CGPoint(
                        x: position.x + TreeLayout.nodeWidth / 2,
                        y: position.y + TreeLayout.nodeHeight / 2
                    ))
                }
                store.pendingScrollTarget = nil
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    Menu {
                        Button("Export as PNG") { GraphImageExporter.export(store: store, as: .png) }
                        Button("Export as JPEG") { GraphImageExporter.export(store: store, as: .jpeg) }
                    } label: {
                        Image(systemName: "camera")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Export the graph as an image")
                    Button { store.zoomAround(factor: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { store.fitGraph(contentSize: layout.size) } label: { Text("Fit") }
                    Button { store.zoomAround(factor: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                if store.legendShown {
                    LegendView()
                        .padding(10)
                }
            }
        }
    }
}

// MARK: - Image export

/// Static full-detail rendering of the graph (edge labels on, selection ring
/// kept, transient flow animation excluded). Shared by the PNG/JPEG export
/// and the headless screenshot composer.
struct GraphCanvas: View {
    let store: AppStore
    let layout: TreeLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            store.canvasBackground.color
            EdgeCanvas(
                edges: layout.edges,
                horizontal: layout.orientation == .leftToRight,
                dimmed: [],
                flagged: store.issues.flaggedEdges,
                flow: [:],
                time: 0,
                zoom: 1.0,
                background: store.canvasBackground
            )
            ForEach(layout.visibleNodes) { node in
                let position = layout.positions[node.id] ?? .zero
                let cardHeight = layout.height(of: node.id)
                NodeCard(
                    node: node,
                    height: cardHeight,
                    collapsedCount: store.collapsed.contains(node.id) ? node.flattened().count - 1 : 0,
                    isSelected: store.selection == node.id,
                    isGhost: store.ghostIDs.contains(node.id),
                    isArrival: false,
                    isReenumerated: false,
                    isDimmed: false,
                    isMatch: false
                )
                .frame(width: TreeLayout.nodeWidth, height: cardHeight)
                .position(
                    x: position.x + TreeLayout.nodeWidth / 2,
                    y: position.y + cardHeight / 2
                )
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }
}

/// Renders the full graph offscreen at 2× and saves PNG or JPEG to ~/Downloads.
@MainActor
enum GraphImageExporter {
    enum ImageFormat: String {
        case png, jpeg
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    static func renderData(store: AppStore, format: ImageFormat) -> Data? {
        let layout = TreeLayout(
            systemRoot: store.systemDisplayNode,
            usbRoots: store.usbDisplayRoots,
            tbRoots: store.tbDisplayRoots,
            pciRoots: store.pciDisplayRoots,
            collapsed: store.collapsed,
            orientation: store.orientation,
            nodeHeights: TagMetrics.nodeHeights(store: store)
        )
        let content = GraphCanvas(store: store, layout: layout)
            .environment(store)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return switch format {
        case .png: rep.representation(using: .png, properties: [:])
        case .jpeg: rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    /// Headless variant: graph canvas to an explicit path.
    @discardableResult
    static func writePNG(store: AppStore, to url: URL) -> Bool {
        guard let data = renderData(store: store, format: .png) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    static func export(store: AppStore, as format: ImageFormat) {
        guard let data = renderData(store: store, format: format) else {
            store.appendEvent(EventRow(kind: .info, title: "Graph export failed", detail: "renderer produced no image"))
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = downloads.appendingPathComponent("portree-graph-\(formatter.string(from: Date())).\(format.fileExtension)")
        do {
            try data.write(to: url)
            store.appendEvent(EventRow(kind: .export, title: "Graph exported (\(format.rawValue.uppercased()))", detail: url.path))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            store.appendEvent(EventRow(kind: .info, title: "Graph export failed", detail: "\(error)"))
        }
    }
}

// MARK: - Scroll-wheel capture (SwiftUI has no native wheel events on macOS)

struct WheelEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let command: Bool
    let location: CGPoint
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    let onWheel: (WheelEvent) -> Void

    /// A hitTest-nil view never receives scrollWheel (AppKit routes scroll via
    /// hitTest), so a passive view can't both catch wheels and pass clicks
    /// through. Instead: a local event monitor that handles scroll events
    /// whose cursor is inside this view's frame, and consumes them.
    final class WheelView: NSView {
        var onWheel: ((WheelEvent) -> Void)?
        // nonisolated(unsafe): deinit is nonisolated and NSEvent.removeMonitor
        // only needs the token; the monitor is installed/removed on main.
        private nonisolated(unsafe) var monitor: Any?

        override var isFlipped: Bool { true }  // top-left origin, matches SwiftUI
        override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks pass through

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let location = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(location) else { return event }
                    self.onWheel?(WheelEvent(
                        deltaX: event.scrollingDeltaX,
                        deltaY: event.scrollingDeltaY,
                        command: event.modifierFlags.contains(.command),
                        location: location
                    ))
                    return nil  // consumed
                }
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.onWheel = onWheel
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) {
        view.onWheel = onWheel
    }
}

// MARK: - Edges

private struct EdgeCanvas: View {
    let edges: [TreeLayout.Edge]
    let horizontal: Bool
    let dimmed: Set<String>
    let flagged: Set<UInt64>
    var flow: [UInt64: Double] = [:]
    var time: TimeInterval = 0
    var zoom: CGFloat = 1.0
    var background: CanvasBackground = .system

    /// Orthogonal elbow with small rounded corners — reads much cleaner than
    /// bezier S-curves on dense trees.
    private func elbow(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        let radius: CGFloat = 7
        if horizontal {
            if abs(from.y - to.y) < 1 {
                path.addLine(to: to)
            } else {
                let midX = (from.x + to.x) / 2
                path.addArc(tangent1End: CGPoint(x: midX, y: from.y),
                            tangent2End: CGPoint(x: midX, y: to.y), radius: radius)
                path.addArc(tangent1End: CGPoint(x: midX, y: to.y),
                            tangent2End: to, radius: radius)
                path.addLine(to: to)
            }
        } else {
            if abs(from.x - to.x) < 1 {
                path.addLine(to: to)
            } else {
                let midY = (from.y + to.y) / 2
                path.addArc(tangent1End: CGPoint(x: from.x, y: midY),
                            tangent2End: CGPoint(x: to.x, y: midY), radius: radius)
                path.addArc(tangent1End: CGPoint(x: to.x, y: midY),
                            tangent2End: to, radius: radius)
                path.addLine(to: to)
            }
        }
        return path
    }

    var body: some View {
        Canvas { context, _ in
            let showLabels = zoom >= 0.55 && edges.count <= 150
            for edge in edges {
                let path = elbow(from: edge.from, to: edge.to)
                let opacity = dimmed.contains(edge.id) ? 0.15 : 0.85

                if edge.isBackbone {
                    // System backbone: soft wide bar + protocol-colored core
                    // (Apple-Fabric-attached devices get the fabric color).
                    let protocolColor: Color = switch edge.childKind {
                    case _ where edge.tier == .fabric: .cyan
                    case .usbController: .blue
                    case .tbDomain: .indigo
                    case .pciDevice: .teal
                    default: .gray
                    }
                    context.stroke(
                        path,
                        with: .color(protocolColor.opacity(opacity * 0.18)),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    context.stroke(
                        path,
                        with: .color(protocolColor.opacity(opacity * 0.75)),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    continue
                }

                // Doctor: the limiting link of a throttled device tints red.
                let color = flagged.contains(edge.childID) ? Color.red : edge.tier.color
                var style = StrokeStyle(lineWidth: Theme.edgeWidth(bps: edge.bps), lineCap: .round)
                if edge.dashed { style.dash = [6, 5] }
                context.stroke(path, with: .color(color.opacity(opacity)), style: style)

                // Video tunnel marker: a pink companion line means this link
                // carries DP/DisplayLink video alongside (or inside) the data.
                if edge.video {
                    let videoPath = path.offsetBy(dx: horizontal ? 0 : -5, dy: horizontal ? -5 : 0)
                    context.stroke(
                        videoPath,
                        with: .color(Color.pink.opacity(opacity * 0.85)),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2.5, 3.5])
                    )
                }

                // Merged hub twin: thin parallel stub for the USB2 personality.
                if edge.secondary {
                    let offsetPath = path.offsetBy(dx: horizontal ? 0 : 5, dy: horizontal ? 5 : 0)
                    context.stroke(
                        offsetPath,
                        with: .color(Tier.usb2.color.opacity(opacity * 0.6)),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                    )
                }

                // Record mode: animated flow on links carrying live traffic.
                if let rate = flow[edge.childID], rate > 1024 {
                    let speed: Double = rate > 50_000_000 ? 160 : (rate > 1_000_000 ? 90 : 40)
                    let flowStyle = StrokeStyle(
                        lineWidth: max(1.6, Theme.edgeWidth(bps: edge.bps) * 0.5),
                        lineCap: .round,
                        dash: [5, 14],
                        dashPhase: -CGFloat(time * speed)
                    )
                    context.stroke(path, with: .color(.white.opacity(0.85)), style: flowStyle)
                }

                // Speed label at the elbow midpoint when zoomed in enough.
                // Low-contrast tiers (infrastructure gray) fall back to the
                // background's muted text color — never gray-on-gray.
                if showLabels, edge.bps > 0, !dimmed.contains(edge.id) {
                    let mid = CGPoint(x: (edge.from.x + edge.to.x) / 2, y: (edge.from.y + edge.to.y) / 2)
                    let textColor = edge.tier == .infrastructure ? background.mutedText : color
                    let text = context.resolve(
                        Text(Format.speedLabel(bps: edge.bps))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(textColor)
                    )
                    let size = text.measure(in: CGSize(width: 120, height: 20))
                    let pad = CGRect(
                        x: mid.x - size.width / 2 - 3.5, y: mid.y - size.height / 2 - 1.5,
                        width: size.width + 7, height: size.height + 3
                    )
                    context.fill(Path(roundedRect: pad, cornerRadius: 4), with: .color(background.chipFill))
                    context.stroke(
                        Path(roundedRect: pad, cornerRadius: 4),
                        with: .color(textColor.opacity(0.35)),
                        style: StrokeStyle(lineWidth: 0.6)
                    )
                    context.draw(text, at: mid)
                }
            }
        }
    }
}

// MARK: - Node card

private struct NodeCard: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode
    let height: CGFloat
    let collapsedCount: Int
    let isSelected: Bool
    let isGhost: Bool
    let isArrival: Bool
    let isReenumerated: Bool
    let isDimmed: Bool
    let isMatch: Bool

    /// Compact: one row of chips that fit, with a "+N…" pill when there are
    /// more; expanded (pill tapped): the full list soft-wrapped — the layout
    /// grows the card to match.
    @ViewBuilder
    private var tagArea: some View {
        let tags = TagList.tags(node: node, store: store, verbose: false)
        if store.expandedTags.contains(node.id) {
            FlowLayout(spacing: 4) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    CapsuleTag(text: tag.text, color: tag.color)
                }
                overflowPill("less")
            }
        } else {
            let fit = TagMetrics.fittingPrefix(tags)
            HStack(spacing: 4) {
                ForEach(Array(tags.prefix(fit).enumerated()), id: \.offset) { _, tag in
                    CapsuleTag(text: tag.text, color: tag.color)
                }
                if tags.count > fit {
                    overflowPill("+\(tags.count - fit)…")
                }
            }
        }
    }

    private func overflowPill(_ label: String) -> some View {
        Button {
            store.toggleTagExpansion(node.id)
        } label: {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

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
                if !node.children.isEmpty || collapsedCount > 0 {
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

            tagArea
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: TreeLayout.nodeWidth, height: height, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    store.overdriveIDs.contains(node.id) ? Color.red
                        : (isReenumerated ? Color.yellow : (isSelected ? Color.accentColor : node.tier.color)),
                    lineWidth: store.overdriveIDs.contains(node.id) ? 2.5
                        : (isSelected || isReenumerated ? 2 : 1.4)
                )
        )
        .overlay(alignment: .topTrailing) {
            // Protocol-stack corner badge for top-level sections.
            if let badge = Theme.protocolBadge(for: node),
               node.kind != .pciDevice || store.parentOf[node.id] == nil || store.allNodes[store.parentOf[node.id]!]?.kind == .system {
                CapsuleTag(text: badge.label, color: badge.color)
                    .offset(x: -6, y: -7)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                if store.isRecording, store.powerOverlay,
                   let power = store.powerSeries[node.id], power.contains(where: { $0 > 0 }) {
                    Sparkline(samples: Array(power.suffix(60)), color: .mint)
                        .frame(height: 8)
                        .opacity(0.6)
                }
                if store.isRecording, let samples = store.series[node.id], samples.contains(where: { $0 > 0 }) {
                    Sparkline(samples: Array(samples.suffix(60)), color: node.tier.color)
                        .frame(height: 13)
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
        }
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
            if let crossLink = node.crossLinkID, store.allNodes[crossLink] != nil {
                Button("Jump to linked node") { store.jump(to: crossLink) }
            }
            Divider()
            Button("Search web for this device") { store.searchWeb(for: node) }
        }
        .animation(.easeOut(duration: 0.35), value: isArrival)
        .help(node.name + (node.speedLabel.isEmpty ? "" : " · \(node.speedLabel)"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Single source of truth for a node's tag chips: the card, the card's
/// expanded state, the inspector footer, and the height estimator all read
/// this list, so they can never disagree.
enum TagList {
    struct Tag {
        let text: String
        let color: Color
    }

    @MainActor
    static func tags(node: DeviceNode, store: AppStore, verbose: Bool) -> [Tag] {
        var tags: [Tag] = []
        if verbose, let badge = Theme.protocolBadge(for: node) {
            tags.append(Tag(text: badge.label, color: badge.color))
        }
        if !node.speedLabel.isEmpty {
            tags.append(Tag(text: node.speedLabel, color: node.tier.color))
        }
        if store.ghostIDs.contains(node.id) {
            tags.append(Tag(text: "removed", color: .red))
            return tags
        }
        if store.overdriveIDs.contains(node.id) {
            tags.append(Tag(text: "⚡ OVERCURRENT", color: .red))
        }
        if store.reenumeratedIDs.contains(node.id) {
            tags.append(Tag(text: "re-enumerated", color: .yellow))
        }
        if let diff = store.baselineDiff {
            if diff.addedIDs.contains(node.id) {
                tags.append(Tag(text: verbose ? "NEW — not in baseline" : "NEW", color: .green))
            } else if diff.changed.contains(where: { $0.id == node.id }) {
                tags.append(Tag(text: verbose ? "CHANGED vs baseline" : "CHANGED", color: .yellow))
            }
        }
        if let nodeIssues = store.issues.byNode[node.id], !nodeIssues.isEmpty {
            if verbose {
                for issue in nodeIssues {
                    tags.append(Tag(
                        text: "⚠︎ \(issue.title)",
                        color: issue.severity == .problem ? .red : (issue.severity == .warning ? .orange : .secondary)
                    ))
                }
            } else {
                tags.append(Tag(
                    text: "⚠︎ \(nodeIssues.count)",
                    color: nodeIssues.contains { $0.severity == .problem } ? .red : .orange
                ))
            }
        }
        if store.isRecording, let rate = store.rates[node.id], rate > 1024 {
            tags.append(Tag(text: Theme.rate(rate), color: .green))
        } else if store.isRecording, node.isHub || node.kind == .usbController {
            let aggregate = store.aggregateRate(for: node)
            if aggregate > 1024 {
                tags.append(Tag(text: "Σ \(Theme.rate(aggregate))", color: .green))
            }
        }
        if store.bandwidthOverlay, let share = store.allocatedShare(of: node) {
            tags.append(Tag(text: "alloc \(Int(share * 100))%", color: .teal))
        }
        if let total = node.properties["Portree Ports Total"]?.intValue, total > 0 {
            let free = node.properties["Portree Ports Free"]?.intValue ?? 0
            tags.append(Tag(text: "\(total - free)/\(total) ports", color: free == 0 ? .orange : .secondary))
        }
        if let power = node.isHub || node.kind == .usbController
            ? { let sum = node.flattened().compactMap(\.powerSinkMA).reduce(0, +); return sum > 0 ? sum : nil }()
            : node.powerSinkMA {
            tags.append(Tag(
                text: node.isHub || node.kind == .usbController ? "Σ \(power) mA" : "\(power) mA",
                color: .mint
            ))
        }
        if let displayMode = store.displayModes[node.id] {
            tags.append(Tag(text: displayMode, color: .pink))
        } else if node.videoTunnelCount > 0 {
            tags.append(Tag(text: "DP \u{00D7}\(node.videoTunnelCount)", color: .pink))
        }
        if let camera = store.cameraInfo[node.id] {
            tags.append(Tag(text: camera.text, color: .pink))
            if camera.inUse {
                tags.append(Tag(text: "● IN USE", color: .red))
            }
        }
        if node.isDisplayLink {
            tags.append(Tag(text: "DisplayLink", color: .pink))
        }
        if node.kind == .system {
            if let tb = node.properties["Measured: Thunderbolt"]?.stringValue {
                tags.append(Tag(text: tb, color: .indigo))
            }
            if let usb = node.properties["Measured: USB"]?.stringValue {
                tags.append(Tag(text: usb, color: .blue))
            }
            if let displays = node.properties["Spec: Displays"]?.stringValue {
                tags.append(Tag(text: displays, color: .secondary))
            }
        }
        if node.isTunneled {
            tags.append(Tag(text: "⚡ tunnel", color: .indigo))
        }
        if node.twin != nil {
            tags.append(Tag(text: verbose ? "2 merged personalities" : "\u{00D7}2", color: .secondary))
        }
        return tags
    }
}

/// Chip-geometry estimates shared by the card's fit calculation and the
/// layout's per-node height (character-width approximation of CapsuleTag).
enum TagMetrics {
    static let rowHeight: CGFloat = 19
    static let contentWidth = TreeLayout.nodeWidth - 18

    static func chipWidth(_ text: String) -> CGFloat {
        CGFloat(text.count) * 6.3 + 17
    }

    /// How many leading tags fit on one compact row, reserving room for +N.
    static func fittingPrefix(_ tags: [TagList.Tag]) -> Int {
        let budget = contentWidth - 34
        var x: CGFloat = 0
        var count = 0
        for tag in tags {
            let width = chipWidth(tag.text)
            if x + width > budget { break }
            x += width + 4
            count += 1
        }
        return max(1, count)
    }

    /// Card height when the tag list is expanded and soft-wrapped.
    static func expandedHeight(_ tags: [TagList.Tag]) -> CGFloat {
        var rows = 1
        var x: CGFloat = 0
        for tag in tags + [TagList.Tag(text: "less", color: .secondary)] {
            let width = chipWidth(tag.text)
            if x > 0, x + width > contentWidth {
                rows += 1
                x = 0
            }
            x += width + 4
        }
        return TreeLayout.nodeHeight + CGFloat(max(0, rows - 1)) * rowHeight
    }

    /// Per-node heights for the layout, from each card's expansion state.
    @MainActor
    static func nodeHeights(store: AppStore) -> [UInt64: CGFloat] {
        var heights: [UInt64: CGFloat] = [:]
        for id in store.expandedTags {
            guard let node = store.allNodes[id] else { continue }
            heights[id] = expandedHeight(TagList.tags(node: node, store: store, verbose: false))
        }
        return heights
    }
}

/// Inspector footer: every tag of the selected node, full-size and wrapped.
struct InspectorTagsView: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode

    var body: some View {
        let tags = TagList.tags(node: node, store: store, verbose: true)
        if !tags.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    CapsuleTag(text: tag.text, color: tag.color)
                }
            }
        }
    }
}

/// Minimal wrapping layout for tag chips (SwiftUI has no built-in flow).
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(proposal: proposal, subviews: subviews).origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(cursor)
            cursor.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, cursor.x - spacing)
        }
        return (origins, CGSize(width: totalWidth, height: cursor.y + rowHeight))
    }
}

/// [Double] as an animatable vector so chart paths MORPH between samples
/// instead of jumping. Unequal lengths are zero-padded so interpolation never
/// crashes while a ring buffer is still filling.
struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector {
        combine(a, b, +)
    }

    static func - (a: AnimatableVector, b: AnimatableVector) -> AnimatableVector {
        combine(a, b, -)
    }

    private static func combine(_ a: AnimatableVector, _ b: AnimatableVector, _ op: (Double, Double) -> Double) -> AnimatableVector {
        let count = max(a.values.count, b.values.count)
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let left = index < a.values.count ? a.values[index] : 0
            let right = index < b.values.count ? b.values[index] : 0
            out[index] = op(left, right)
        }
        return AnimatableVector(values: out)
    }

    mutating func scale(by rhs: Double) {
        for index in values.indices { values[index] *= rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

private struct LiveChartShape: Shape {
    var vector: AnimatableVector
    var closed: Bool   // area fill variant closes down to the baseline

    var animatableData: AnimatableVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let values = vector.values
        guard values.count > 1 else { return path }
        let peak = max(values.max() ?? 1, 1)
        let stepX = rect.width / CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.minY + rect.height * (1 - CGFloat(values[index] / peak))
            )
        }
        if closed { path.move(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        for index in values.indices {
            if index == 0 && !closed { path.move(to: point(0)) } else { path.addLine(to: point(index)) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Animated line chart with a soft gradient fill — the ring is padded to a
/// constant length so each new sample morphs the path smoothly (≈1 s linear,
/// matching the sampling tick) instead of snapping.
struct Sparkline: View {
    let samples: [Double]
    let color: Color
    var capacity: Int = 120
    var filled: Bool = true
    var lineWidth: CGFloat = 1.4

    private var padded: [Double] {
        let tail = Array(samples.suffix(capacity))
        return Array(repeating: 0, count: max(0, capacity - tail.count)) + tail
    }

    var body: some View {
        let vector = AnimatableVector(values: padded)
        ZStack {
            if filled {
                LiveChartShape(vector: vector, closed: true)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.32), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
            LiveChartShape(vector: vector, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .animation(.linear(duration: 0.95), value: padded)
        .drawingGroup()
    }
}

struct CapsuleTag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background {
                // Opaque base under the tint — pure-transparency chips are
                // unreadable over canvas edges.
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                Capsule().fill(color.opacity(0.14))
            }
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.8))
            .fixedSize()
    }
}
