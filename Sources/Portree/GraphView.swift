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
    @State private var hoveredEdgeID: String?

    // MARK: Edge hit-testing (content space, mirrors the elbow geometry)

    private func contentPoint(_ p: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - store.panOffset.width) / zoom, y: (p.y - store.panOffset.height) / zoom)
    }

    private func nearestEdge(to p: CGPoint, in layout: TreeLayout, zoom: CGFloat) -> TreeLayout.Edge? {
        let threshold = 12 / max(zoom, 0.4)
        var best: (edge: TreeLayout.Edge, distance: CGFloat, endpoint: CGFloat)?
        for edge in layout.edges {
            let d = Self.elbowDistance(
                from: edge.from, to: edge.to,
                horizontal: layout.orientation == .leftToRight, point: p
            )
            guard d < threshold else { continue }
            // Sibling edges share their trunk segments exactly — ties break
            // toward the edge whose child endpoint is closest to the cursor.
            let endpoint = hypot(p.x - edge.to.x, p.y - edge.to.y)
            if best == nil
                || d < best!.distance - 0.5
                || (abs(d - best!.distance) <= 0.5 && endpoint < best!.endpoint) {
                best = (edge, d, endpoint)
            }
        }
        return best?.edge
    }

    private static func elbowDistance(from: CGPoint, to: CGPoint, horizontal: Bool, point: CGPoint) -> CGFloat {
        let corners: [CGPoint] = horizontal
            ? [from, CGPoint(x: (from.x + to.x) / 2, y: from.y), CGPoint(x: (from.x + to.x) / 2, y: to.y), to]
            : [from, CGPoint(x: from.x, y: (from.y + to.y) / 2), CGPoint(x: to.x, y: (from.y + to.y) / 2), to]
        var best = CGFloat.infinity
        for i in 0..<(corners.count - 1) {
            best = min(best, segmentDistance(point, corners[i], corners[i + 1]))
        }
        return best
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Cards render at TRUE size for the settled zoom (frames, positions and
    /// fonts all multiplied by `zoom`) so text stays vector-crisp — a layer
    /// scaleEffect would magnify already-rasterized textures. Layout stays in
    /// unscaled content space: scaling commutes because every point constant
    /// in a card scales linearly.
    @ViewBuilder
    private func graphContent(layout: TreeLayout, search: (matches: Set<UInt64>, visible: Set<UInt64>)?, zoom: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
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
                    isDimmed: (search.map { !$0.visible.contains(node.id) } ?? false)
                        || (store.focusedNodeID.map { $0 != node.id } ?? false),
                    isMatch: (search.map { $0.matches.contains(node.id) } ?? false)
                        || store.focusedNodeID == node.id
                )
                .frame(width: TreeLayout.nodeWidth * zoom, height: cardHeight * zoom)
                .position(
                    x: (position.x + TreeLayout.nodeWidth / 2) * zoom,
                    y: (position.y + cardHeight / 2) * zoom
                )
            }
        }
        .environment(\.zoomScale, zoom)
    }

    var body: some View {
        let layout = store.currentLayout()
        let search = store.searchResult

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                store.canvasBackground.color

                // Edges render OUTSIDE the scaled layer, at full viewport
                // resolution, with pan/zoom applied to the canvas CTM — a
                // Canvas inside scaleEffect is rasterized at logical size and
                // goes blurry when zoomed in.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.isRecording)) { timeline in
                    EdgeCanvas(
                        edges: layout.edges,
                        horizontal: layout.orientation == .leftToRight,
                        dimmed: {
                            var dim = search.map { s in
                                Set(layout.edges.filter { !s.visible.contains($0.childID) }.map(\.id))
                            } ?? []
                            if let focus = store.focusedNodeID {
                                dim.formUnion(layout.edges.filter { $0.childID != focus }.map(\.id))
                            }
                            return dim
                        }(),
                        flagged: store.issues.flaggedEdges,
                        flow: store.isRecording ? store.rates : [:],
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        zoom: store.zoom * gestureZoom,
                        background: store.canvasBackground,
                        canvasOffset: store.panOffset,
                        highlightID: hoveredEdgeID
                    )
                }

                // Settled zoom is geometric (crisp); only the LIVE pinch uses
                // a layer scaleEffect — transient blur under the fingers,
                // re-rendered sharp the moment the gesture ends.
                graphContent(layout: layout, search: search, zoom: store.zoom)
                    .frame(
                        width: layout.size.width * store.zoom,
                        height: layout.size.height * store.zoom,
                        alignment: .topLeading
                    )
                    .scaleEffect(gestureZoom, anchor: .topLeading)
                    .offset(store.panOffset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let zoom = store.zoom * gestureZoom
                let point = contentPoint(value.location, zoom: zoom)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if let edge = nearestEdge(to: point, in: layout, zoom: zoom) {
                        store.linkPopover = AppStore.LinkSelection(childID: edge.childID)
                    } else {
                        store.linkPopover = nil
                    }
                }
            })
            .onContinuousHover { phase in
                let zoom = store.zoom * gestureZoom
                switch phase {
                case .active(let location):
                    let edge = nearestEdge(to: contentPoint(location, zoom: zoom), in: layout, zoom: zoom)
                    if hoveredEdgeID != edge?.id {
                        hoveredEdgeID = edge?.id
                        if edge != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                case .ended:
                    if hoveredEdgeID != nil {
                        hoveredEdgeID = nil
                        NSCursor.arrow.set()
                    }
                }
            }
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
                        y: position.y + layout.height(of: target) / 2
                    ))
                }
                store.pendingScrollTarget = nil
            }
            // Fixed chrome layer: legend bottom-left, zoom/fit/export
            // bottom-right. Lives inside the stage with an explicit z-order so
            // no overlay-resolution quirk can swallow it again.
            .overlay {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if store.legendShown {
                            LegendView()
                        }
                        Spacer()
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
                                .help("Zoom out (⌘−)")
                            Button { store.fitGraph(contentSize: layout.size) } label: { Text("Fit") }
                                .help("Fit the whole tree")
                            Button { store.zoomAround(factor: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom in (⌘+)")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .padding(10)
                }
                .zIndex(10)
                .allowsHitTesting(true)
            }
            .overlay {
                // Anchor on the CURRENT layout's edge midpoint — a frozen
                // click point goes stale the moment the tree reflows.
                if let selection = store.linkPopover,
                   let child = store.allNodes[selection.childID],
                   let edge = layout.edges.first(where: { $0.childID == selection.childID }) {
                    let zoom = store.zoom * gestureZoom
                    let mid = CGPoint(x: (edge.from.x + edge.to.x) / 2, y: (edge.from.y + edge.to.y) / 2)
                    let anchor = CGPoint(
                        x: mid.x * zoom + store.panOffset.width,
                        y: mid.y * zoom + store.panOffset.height
                    )
                    LinkPopoverView(
                        child: child,
                        parent: store.parentOf[child.id].flatMap { store.allNodes[$0] }
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            store.linkPopover = nil
                        }
                    }
                    .position(
                        x: min(max(anchor.x, 170), max(geo.size.width - 170, 170)),
                        y: max(anchor.y - 150, 130)
                    )
                    .transition(.scale(scale: 0.88, anchor: .bottom).combined(with: .opacity))
                    .zIndex(20)
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
    /// Pan offset applied to the drawing CTM (interactive view only — the
    /// canvas fills the viewport and pans/zooms its coordinate space, so
    /// strokes and labels stay vector-sharp at any zoom).
    var canvasOffset: CGSize = .zero
    /// Edge under the cursor — drawn with a soft glow as the click
    /// affordance for the link popover.
    var highlightID: String?

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
            context.translateBy(x: canvasOffset.width, y: canvasOffset.height)
            context.scaleBy(x: zoom, y: zoom)
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
                if edge.id == highlightID {
                    context.stroke(
                        path,
                        with: .color(color.opacity(0.3)),
                        style: StrokeStyle(lineWidth: Theme.edgeWidth(bps: edge.bps) + 6, lineCap: .round)
                    )
                }
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
                    // Stays .font (Text method): context.resolve needs Text,
                    // and edge labels scale with canvas zoom, not UI fonts.
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
    @Environment(\.zoomScale) private var z
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
            FlowLayout(spacing: 4 * z) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    CapsuleTag(text: tag.text, color: tag.color)
                }
                overflowPill("less")
            }
        } else {
            let fit = TagMetrics.fittingPrefix(tags, scale: store.fontScale)
            HStack(spacing: 4 * z) {
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
                .appFont(8.5, weight: .bold)
                .padding(.horizontal, 5 * z)
                .padding(.vertical, 1 * z)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * z) {
            HStack(spacing: 7 * z) {
                Image(systemName: store.effectiveCategory(of: node).symbol)
                    .appFont(12, weight: .medium)
                    .foregroundStyle(node.tier.color)
                    .frame(width: 22 * z, height: 22 * z)
                    .background(node.tier.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5 * z))

                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name)
                        .appFont(11.5, weight: .semibold)
                        .strikethrough(isGhost)
                        .lineLimit(1)
                    Text(node.subtitle)
                        .appFont(9.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2 * z)
                if !node.children.isEmpty || collapsedCount > 0 {
                    Button {
                        store.toggleCollapsed(node.id)
                    } label: {
                        Text(collapsedCount > 0 ? "+\(collapsedCount)" : "−")
                            .appFont(9.5, weight: .bold)
                            .padding(.horizontal, 6 * z)
                            .padding(.vertical, 1 * z)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            tagArea
        }
        .padding(.horizontal, 9 * z)
        .padding(.vertical, 6 * z)
        .frame(width: TreeLayout.nodeWidth * z, height: height * z, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9 * z)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9 * z)
                .stroke(
                    store.overdriveIDs.contains(node.id) || store.untrustedIDs.contains(node.id) ? Color.red
                        : (isReenumerated ? Color.yellow : (isSelected ? Color.accentColor : node.tier.color)),
                    lineWidth: (store.overdriveIDs.contains(node.id) || store.untrustedIDs.contains(node.id) ? 2.5
                        : (isSelected || isReenumerated ? 2 : 1.4)) * z
                )
        )
        .overlay(alignment: .topTrailing) {
            // Protocol-stack corner badge for top-level sections.
            if let badge = Theme.protocolBadge(for: node),
               node.kind != .pciDevice || store.parentOf[node.id] == nil || store.allNodes[store.parentOf[node.id]!]?.kind == .system {
                CapsuleTag(text: badge.label, color: badge.color)
                    .offset(x: -6 * z, y: -7 * z)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1 * z) {
                if store.isRecording, store.powerOverlay,
                   let power = store.powerSeries[node.id], power.contains(where: { $0 > 0 }) {
                    Sparkline(samples: power, color: .mint, capacity: 60, tick: store.sampleCount)
                        .frame(height: 8 * z)
                        .opacity(0.6)
                }
                if store.isRecording, let samples = store.series[node.id], samples.contains(where: { $0 > 0 }) {
                    Sparkline(samples: samples, color: node.tier.color, capacity: 60, tick: store.sampleCount)
                        .frame(height: 13 * z)
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 9 * z)
            .padding(.bottom, 2 * z)
            .allowsHitTesting(false)
        }
        .modifier(CardGlow(
            // Shadow forces offscreen rasterization of the card, which blurs
            // under zoom — only attach it while a glow is actually showing.
            color: store.untrustedIDs.contains(node.id) ? Color.red.opacity(0.75)
                : isArrival ? Color.yellow.opacity(0.8)
                : isMatch ? Color.yellow.opacity(0.5) : nil,
            radius: (store.untrustedIDs.contains(node.id) ? 9 : (isArrival ? 10 : 7)) * z
        ))
        .opacity(isGhost ? 0.45 : (isDimmed ? 0.25 : 1.0))
        .contentShape(RoundedRectangle(cornerRadius: 9 * z))
        .onTapGesture { store.selection = node.id }
        .contextMenu {
            if store.untrustedIDs.contains(node.id) {
                Button("Trust this device") { store.trustDevice(node) }
                Divider()
            }
            if !node.children.isEmpty {
                Button(store.collapsed.contains(node.id) ? "Expand subtree" : "Collapse subtree") {
                    store.toggleCollapsed(node.id)
                }
            }
            Button(store.expandedTags.contains(node.id) ? "Collapse tags" : "Expand tags") {
                store.toggleTagExpansion(node.id)
            }
            Divider()
            Button("Copy device name") { copy(node.name) }
            if let idPair = node.idPairLabel {
                Button("Copy device ID") { copy(idPair) }
            }
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
            Button("Copy Wireshark capture recipe") { store.copyCaptureRecipe(for: node) }
        }
        .animation(.easeOut(duration: 0.35), value: isArrival)
        .help(node.name + (node.speedLabel.isEmpty ? "" : " · \(node.speedLabel)"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Floating card for a clicked edge: the connection's facts — negotiated
/// link, cable eMarker identity (first hop only; deeper cables are not
/// visible to the host's port manager), PD power contract, Doctor flags.
private struct LinkPopoverView: View {
    @Environment(AppStore.self) private var store
    let child: DeviceNode
    let parent: DeviceNode?
    let dismiss: () -> Void

    var body: some View {
        let link = store.portLink(for: child)
        let issues = store.issues.byNode[child.id] ?? []

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(child.tier.color)
                    .frame(width: 16, height: 4)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(parent?.name ?? "Mac") → \(child.name)")
                        .appFont(11.5, weight: .semibold)
                        .lineLimit(1)
                    Text(link != nil ? "physical cable · receptacle \(link!.portNumber)" : "link")
                        .appFont(9)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .appFont(12)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if !child.speedLabel.isEmpty {
                    row("Negotiated", child.speedLabel)
                }
                if child.carriesVideo {
                    row("Video", child.videoTunnelCount > 0 ? "DP ×\(child.videoTunnelCount) tunneled" : "yes")
                }
                if let power = child.powerSinkMA {
                    row("Power sink", "\(power) mA")
                }
                if let marker = link?.eMarker {
                    divider("Cable (eMarker)")
                    if let type = marker.productTypeDescription { row("Type", type) }
                    if let vid = marker.vendorID {
                        row("Maker", "\(Format.hex(vid, width: 4))\(marker.productID.map { ":\(Format.hex($0, width: 4))" } ?? "")")
                    }
                    if let speed = marker.ratedSpeed { row("Rated", speed) }
                    if let current = marker.ratedCurrent { row("Current", current + (marker.maxVBusVoltage.map { " · \($0)" } ?? "")) }
                    if let latency = marker.latencyLabel { row("Latency", latency) }
                    if let termination = marker.termination { row("Termination", termination) }
                    if let construction = marker.construction { row("Build", construction) }
                } else if let link, link.active {
                    divider("Cable")
                    row("eMarker", "none — legacy/unmarked cable")
                }
                if let contract = link?.powerContract {
                    divider("Power in")
                    row("Contract", contract.label)
                    if let inMW = store.snapshot?.power?.systemPowerInMW {
                        row("Drawing", String(format: "%.1f W now", Double(inMW) / 1000))
                    }
                }
            }

            ForEach(issues.prefix(2)) { issue in
                Label(issue.title, systemImage: issue.severity == .problem
                    ? "exclamationmark.octagon.fill"
                    : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                    .appFont(9.5)
                    .foregroundStyle(issue.severity == .problem ? .red : (issue.severity == .warning ? .orange : .secondary))
                    .lineLimit(1)
            }
        }
        .padding(11)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 7)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).appFont(9.5).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).appFont(10, weight: .medium).lineLimit(1)
        }
    }

    private func divider(_ title: String) -> some View {
        GridRow {
            Text(title)
                .appFont(8.5, weight: .bold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .gridCellColumns(2)
                .padding(.top, 3)
        }
    }
}

/// Shadow forces the card subtree into an offscreen raster, which scaleEffect
/// then upscales blurrily — so the modifier only exists while glowing.
private struct CardGlow: ViewModifier {
    let color: Color?
    let radius: CGFloat

    func body(content: Content) -> some View {
        if let color {
            content.shadow(color: color, radius: radius)
        } else {
            content
        }
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
        if store.untrustedIDs.contains(node.id) {
            tags.append(Tag(text: verbose ? "UNKNOWN — never seen on this Mac" : "⚠︎ UNKNOWN", color: .red))
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
        if store.isRecording, let rate = store.rates[node.id] {
            // An entry existing means this node HAS counters; 0 = idle.
            tags.append(rate > 1024
                ? Tag(text: Theme.rate(rate), color: .green)
                : Tag(text: "0 B/s", color: .secondary))
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
            appendSplit(displayMode, color: .pink, to: &tags)
            // Display-first dual label: a matched monitor that also exposes
            // downstream devices is a display WITH a built-in hub.
            if node.kind != .system, node.kind != .displaySink,
               node.category != .display, !node.children.isEmpty {
                tags.append(Tag(text: "built-in hub", color: .secondary))
            }
        } else if node.videoTunnelCount > 0 {
            tags.append(Tag(text: "DP \u{00D7}\(node.videoTunnelCount)", color: .pink))
        }
        if node.kind == .displaySink {
            if let lanes = node.properties["LaneCount"]?.intValue {
                tags.append(Tag(text: "\(lanes) DP lanes", color: .pink))
            }
            if let dfp = node.properties["Metadata"]?.dictValue?["DFP Type Description"]?.stringValue {
                tags.append(Tag(text: "sink: \(dfp)", color: .pink))
            }
        }
        // Display-output occupancy on adapters/docks (HPD per DP OUT). On a
        // hub monitor one used output IS its own panel — say so, or "1/2"
        // reads as an occupied external port.
        if let total = node.dpOutTotal, total > 0 {
            let used = node.dpOutUsed ?? 0
            let ownPanel = store.displayModes[node.id] != nil && node.kind == .tbSwitch
            tags.append(Tag(
                text: "DP out \(used)/\(total)\(ownPanel && used > 0 ? " incl. panel" : "")",
                color: used > 0 ? .pink : .secondary
            ))
        }
        if let camera = store.cameraInfo[node.id] {
            appendSplit(camera.text, color: .pink, to: &tags)
            if camera.inUse {
                tags.append(Tag(text: "● IN USE", color: .red))
            }
        }
        if let gfx = node.usbGraphicsVendor {
            tags.append(Tag(text: verbose ? "USB graphics · \(gfx)" : gfx, color: .pink))
        }
        if node.isBillboard {
            tags.append(Tag(text: verbose ? "USB-C alt-mode adapter (billboard)" : "alt-mode adapter", color: .orange))
        }
        if node.kind == .system {
            if let tb = node.properties["Measured: Thunderbolt"]?.stringValue {
                appendSplit(tb, color: .indigo, to: &tags)
            }
            if let usb = node.properties["Measured: USB"]?.stringValue {
                appendSplit(usb, color: .blue, to: &tags)
            }
            if let displays = node.properties["Spec: Displays"]?.stringValue {
                appendSplit(displays, color: .secondary, to: &tags)
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

    /// Compound "a · b · c" strings become one chip per part — a single
    /// mega-chip can never wrap and always overflows the card frame.
    private static func appendSplit(_ text: String, color: Color, to tags: inout [Tag]) {
        for part in text.components(separatedBy: " · ") where !part.isEmpty {
            tags.append(Tag(text: part, color: color))
        }
    }
}

/// Chip-geometry estimates shared by the card's fit calculation and the
/// layout's per-node height (character-width approximation of CapsuleTag).
enum TagMetrics {
    static let contentWidth = TreeLayout.nodeWidth - 18

    static func rowHeight(scale: CGFloat) -> CGFloat { 19 * scale }

    static func chipWidth(_ text: String, scale: CGFloat) -> CGFloat {
        (CGFloat(text.count) * 6.3 + 17) * scale
    }

    /// How many leading tags fit on one compact row, reserving room for +N.
    static func fittingPrefix(_ tags: [TagList.Tag], scale: CGFloat) -> Int {
        let budget = contentWidth - 34 * scale
        var x: CGFloat = 0
        var count = 0
        for tag in tags {
            let width = chipWidth(tag.text, scale: scale)
            if x + width > budget { break }
            x += width + 4
            count += 1
        }
        return max(1, count)
    }

    /// Card height when the tag list is expanded and soft-wrapped.
    static func expandedHeight(_ tags: [TagList.Tag], scale: CGFloat) -> CGFloat {
        var rows = 1
        var x: CGFloat = 0
        for tag in tags + [TagList.Tag(text: "less", color: .secondary)] {
            let width = chipWidth(tag.text, scale: scale)
            if x > 0, x + width > contentWidth {
                rows += 1
                x = 0
            }
            x += width + 4
        }
        return TreeLayout.nodeHeight + CGFloat(max(0, rows - 1)) * rowHeight(scale: scale)
    }

    /// Per-node heights for the layout, from each card's expansion state.
    @MainActor
    static func nodeHeights(store: AppStore) -> [UInt64: CGFloat] {
        var heights: [UInt64: CGFloat] = [:]
        for id in store.expandedTags {
            guard let node = store.allNodes[id] else { continue }
            heights[id] = expandedHeight(
                TagList.tags(node: node, store: store, verbose: false),
                scale: store.fontScale
            )
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
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    CapsuleTag(text: tag.text, color: tag.color, size: 11)
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

/// Scrolling live chart that TRANSLATES instead of morphing: every sample is
/// drawn at an absolute x keyed to the global tick, and only a horizontal
/// offset animates each second — history pixels stay rigid while the strip
/// slides left and the newest point enters from the right edge. (The earlier
/// index-space interpolation made old data visibly undulate.)
struct Sparkline: View {
    let samples: [Double]
    let color: Color
    var capacity: Int = 120
    var filled: Bool = true
    var lineWidth: CGFloat = 1.4
    /// Monotonic sample counter (store.sampleCount): drives the scroll.
    var tick: Int = 0

    var body: some View {
        GeometryReader { geo in
            chart(in: geo.size)
                .offset(x: geo.size.width - (geo.size.width / CGFloat(max(capacity - 1, 1))) - CGFloat(tick) * (geo.size.width / CGFloat(max(capacity - 1, 1))))
                .animation(.linear(duration: 1.0), value: tick)
        }
        .clipped()
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let window = Array(samples.suffix(capacity))
        guard window.count > 1 else { return [] }
        let stepX = size.width / CGFloat(max(capacity - 1, 1))
        let peak = max(window.max() ?? 1, 1)
        return window.enumerated().map { j, value in
            CGPoint(
                x: CGFloat(tick - (window.count - 1 - j)) * stepX,  // absolute x: global tick index
                y: size.height * (1 - CGFloat(value / peak))
            )
        }
    }

    @ViewBuilder
    private func chart(in size: CGSize) -> some View {
        let pts = points(in: size)
        ZStack {
            if filled, pts.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: pts[0].x, y: size.height))
                    for point in pts { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [color.opacity(0.32), color.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            if pts.count > 1 {
                Path { path in
                    path.move(to: pts[0])
                    for point in pts.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

struct CapsuleTag: View {
    @Environment(\.zoomScale) private var z
    let text: String
    var color: Color = .secondary
    /// Cards stay dense at 8.5; the inspector renders readable 11pt chips.
    var size: CGFloat = 8.5

    var body: some View {
        Text(text)
            .appFont(size, weight: .semibold)
            .padding(.horizontal, (size > 9 ? 7 : 5) * z)
            .padding(.vertical, (size > 9 ? 2 : 1) * z)
            .foregroundStyle(color)
            .background {
                // Opaque base under the tint — pure-transparency chips are
                // unreadable over canvas edges.
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                Capsule().fill(color.opacity(0.14))
            }
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.8 * z))
            .fixedSize()
    }
}
