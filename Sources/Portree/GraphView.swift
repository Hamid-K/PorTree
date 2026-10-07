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
            orientation: store.orientation
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
                NodeCard(
                    node: node,
                    collapsedCount: store.collapsed.contains(node.id) ? node.flattened().count - 1 : 0,
                    isSelected: store.selection == node.id,
                    isGhost: store.ghostIDs.contains(node.id),
                    isArrival: false,
                    isReenumerated: false,
                    isDimmed: false,
                    isMatch: false
                )
                .frame(width: TreeLayout.nodeWidth, height: TreeLayout.nodeHeight)
                .position(
                    x: position.x + TreeLayout.nodeWidth / 2,
                    y: position.y + TreeLayout.nodeHeight / 2
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

    static func export(store: AppStore, as format: ImageFormat) {
        let layout = TreeLayout(
            systemRoot: store.systemDisplayNode,
            usbRoots: store.usbDisplayRoots,
            tbRoots: store.tbDisplayRoots,
            pciRoots: store.pciDisplayRoots,
            collapsed: store.collapsed,
            orientation: store.orientation
        )
        let content = GraphCanvas(store: store, layout: layout)
            .environment(store)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else {
            store.appendEvent(EventRow(kind: .info, title: "Graph export failed", detail: "renderer produced no image"))
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let data: Data? = switch format {
        case .png: rep.representation(using: .png, properties: [:])
        case .jpeg: rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
        guard let data else {
            store.appendEvent(EventRow(kind: .info, title: "Graph export failed", detail: "could not encode \(format.rawValue)"))
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
    let collapsedCount: Int
    let isSelected: Bool
    let isGhost: Bool
    let isArrival: Bool
    let isReenumerated: Bool
    let isDimmed: Bool
    let isMatch: Bool

    private var subtreePowerMA: Int64? {
        guard node.isHub || node.kind == .usbController else { return node.powerSinkMA }
        let total = node.flattened().compactMap(\.powerSinkMA).reduce(0, +)
        return total > 0 ? total : nil
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

            HStack(spacing: 4) {
                if !node.speedLabel.isEmpty {
                    CapsuleTag(text: node.speedLabel, color: node.tier.color)
                }
                if isGhost {
                    CapsuleTag(text: "removed", color: .red)
                } else {
                    if let nodeIssues = store.issues.byNode[node.id], !nodeIssues.isEmpty {
                        CapsuleTag(
                            text: "⚠︎ \(nodeIssues.count)",
                            color: nodeIssues.contains { $0.severity == .problem } ? .red : .orange
                        )
                    }
                    if store.isRecording, let rate = store.rates[node.id], rate > 1024 {
                        CapsuleTag(text: Theme.rate(rate), color: .green)
                    }
                    if store.bandwidthOverlay, let share = store.allocatedShare(of: node) {
                        CapsuleTag(text: "alloc \(Int(share * 100))%", color: .teal)
                    }
                    if let power = subtreePowerMA {
                        CapsuleTag(
                            text: node.isHub || node.kind == .usbController ? "Σ \(power) mA" : "\(power) mA",
                            color: .mint
                        )
                    }
                    if node.videoTunnelCount > 0 {
                        CapsuleTag(text: "DP ×\(node.videoTunnelCount)", color: .pink)
                    }
                    if node.isDisplayLink { CapsuleTag(text: "DisplayLink", color: .pink) }
                    if node.kind == .system {
                        if let tb = node.properties["Measured: Thunderbolt"]?.stringValue {
                            CapsuleTag(text: tb, color: .indigo)
                        }
                        if let usb = node.properties["Measured: USB"]?.stringValue {
                            CapsuleTag(text: usb, color: .blue)
                        }
                        if let displays = node.properties["Spec: Displays"]?.stringValue {
                            CapsuleTag(text: displays, color: .secondary)
                        }
                    }
                    if node.isTunneled { CapsuleTag(text: "⚡ tunnel", color: .indigo) }
                    if node.twin != nil { CapsuleTag(text: "×2", color: .secondary) }
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
        .overlay(alignment: .topTrailing) {
            // Protocol-stack corner badge for top-level sections.
            if let badge = Theme.protocolBadge(for: node),
               node.kind != .pciDevice || store.parentOf[node.id] == nil || store.allNodes[store.parentOf[node.id]!]?.kind == .system {
                CapsuleTag(text: badge.label, color: badge.color)
                    .offset(x: -6, y: -7)
            }
        }
        .overlay(alignment: .bottom) {
            if store.isRecording, let samples = store.series[node.id], samples.contains(where: { $0 > 0 }) {
                Sparkline(samples: Array(samples.suffix(60)), color: node.tier.color)
                    .frame(height: 13)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 2)
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }
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
        }
        .animation(.easeOut(duration: 0.35), value: isArrival)
        .help(node.name + (node.speedLabel.isEmpty ? "" : " · \(node.speedLabel)"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Tiny last-60s throughput trace drawn along a node card's bottom while
/// recording.
struct Sparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let peak = max(samples.max() ?? 1, 1)
            Path { path in
                guard samples.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(samples.count - 1)
                for (index, value) in samples.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * stepX,
                        y: geo.size.height * (1 - CGFloat(value / peak))
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
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
