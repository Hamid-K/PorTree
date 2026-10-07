import SwiftUI
import AppKit
import PortreeCore

/// The single MainActor owner of all mutable UI state. The IOKit queue hands
/// in Sendable snapshots/events; views only read this store. The tree is
/// always replaced wholesale (never patched); transient presentation —
/// arrival glows, removal ghosts, re-enumeration pulses — is overlaid on top.
@MainActor
@Observable
final class AppStore {

    static let shared = AppStore()

    // MARK: Live data
    private(set) var snapshot: Snapshot?
    private(set) var allNodes: [UInt64: DeviceNode] = [:]
    private(set) var parentOf: [UInt64: UInt64] = [:]
    private(set) var events: [EventRow] = []
    private(set) var lastRefresh: Date?
    private(set) var issues = Doctor.Report.empty

    // Transient presentation state
    private(set) var ghostIDs: Set<UInt64> = []
    private(set) var arrivalIDs: Set<UInt64> = []
    private(set) var reenumeratedIDs: Set<UInt64> = []
    private var ghostNodes: [(parentID: UInt64, node: DeviceNode)] = []

    // MARK: UI state
    var selection: UInt64?
    var collapsed: Set<UInt64> = []
    var searchText = ""
    var inspectorShown = true
    var drawerShown = true
    var logPaused = false
    var zoom: CGFloat = 1.0
    var pendingScrollTarget: UInt64?
    var toolboxShown = false
    /// Persistent legend overlay in the graph corner (palette button toggles).
    var legendShown = true
    /// Bandwidth overlay (allocated share + live rates) — OFF by default.
    var bandwidthOverlay = false
    var orientation: LayoutOrientation = .leftToRight
    var canvasBackground: CanvasBackground = .system
    /// Graph pan offset in viewport points (content is scaled by `zoom`).
    var panOffset: CGSize = CGSize(width: 24, height: 24)
    /// Last known graph viewport, for fit/zoom-around-center math.
    var lastViewport: CGSize = .zero

    // MARK: Record mode (live throughput; real counters only)
    private(set) var isRecording = false
    private(set) var recordingStart: Date?
    private(set) var rates: [UInt64: Double] = [:]      // bytes/sec, current
    private(set) var series: [UInt64: [Double]] = [:]   // ring, 300 samples
    private(set) var totalSeries: [Double] = []         // aggregate, for the traffic strip
    private(set) var sampleCount = 0
    private var sampler: BandwidthSampler?

    private var monitor: HotplugMonitor?
    private let logWriter = EventLogWriter()
    private var previousSnapshot: Snapshot?

    // MARK: Lifecycle

    func start() {
        guard monitor == nil else { return }
        let monitor = HotplugMonitor(
            onEvents: { events in
                Task { @MainActor in AppStore.shared.handleRaw(events) }
            },
            onSnapshot: { snapshot in
                Task { @MainActor in AppStore.shared.apply(snapshot) }
            }
        )
        self.monitor = monitor
        monitor.start()
    }

    func refresh() {
        monitor?.rescan()
        appendEvent(EventRow(kind: .rescan, title: "Manual rescan", detail: "⌘R"))
    }

    func rescanSilently() {
        monitor?.rescan()
    }

    // MARK: Snapshot handling

    private func apply(_ new: Snapshot) {
        let diff = DiffEngine.diff(old: previousSnapshot, new: new)
        let newByID = new.allByID()

        // Re-enumerations within one debounce window (electrical bounce).
        for item in diff.reenumerated {
            markReenumerated(id: item.newID, name: item.oldNode.name, confident: item.confident)
        }

        // Human-speed replugs land in a LATER snapshot than the removal: an
        // arrival whose identity matches a live ghost collapses into one
        // re-enumeration — never ghost + new node side by side (DESIGN §4).
        var arrivals = diff.addedIDs
        for id in arrivals {
            guard let node = newByID[id], let identity = node.deviceIdentity,
                  let ghostIndex = ghostNodes.firstIndex(where: {
                      $0.node.deviceIdentity?.key == identity.key
                  }) else { continue }
            let ghost = ghostNodes[ghostIndex].node
            ghostNodes.remove(at: ghostIndex)
            ghostIDs.remove(ghost.id)
            arrivals.remove(id)
            markReenumerated(id: id, name: ghost.name, confident: identity.confident)
        }

        // Removals: keep a ghost in place for 4 s (flaky-cable debugging).
        for node in diff.removedNodes {
            guard let parent = previousParent(of: node.id) else { continue }
            var ghost = node
            ghost.children = []  // subtree members get their own ghosts
            ghostNodes.append((parentID: parent, node: ghost))
            ghostIDs.insert(node.id)
            expire(after: 4.0) {
                $0.ghostIDs.remove(node.id)
                $0.ghostNodes.removeAll { $0.node.id == node.id }
                $0.reindex()  // indexes must not keep pointing at expired ghosts
            }
        }

        // Arrivals: glow briefly.
        for id in arrivals {
            arrivalIDs.insert(id)
            expire(after: 1.6) { $0.arrivalIDs.remove(id) }
        }

        withAnimation(.spring(duration: 0.35)) {
            previousSnapshot = new
            snapshot = new
            lastRefresh = new.takenAt
            reindex()
        }

        issues = Doctor.diagnose(snapshot: new)

        if selection == nil {
            // Defer: assigning selection inside the same transaction as the
            // tree swap makes AppKit's List delegate re-enter.
            let candidate = new.allRoots.first?.children.first?.id ?? new.allRoots.first?.id
            Task { @MainActor in if self.selection == nil { self.selection = candidate } }
        }
    }

    private func previousParent(of id: UInt64) -> UInt64? {
        parentOf[id]
    }

    private func markReenumerated(id: UInt64, name: String, confident: Bool) {
        reenumeratedIDs.insert(id)
        appendEvent(EventRow(
            kind: .reenumerated,
            title: "Re-enumerated — \(name)",
            detail: confident ? "same identity, new session" : "identity match low-confidence (no serial)",
            nodeID: id
        ))
        expire(after: 2.5) { $0.reenumeratedIDs.remove(id) }
    }

    private func reindex() {
        var nodes: [UInt64: DeviceNode] = [:]
        var parents: [UInt64: UInt64] = [:]
        func walk(_ node: DeviceNode) {
            nodes[node.id] = node
            for child in node.children {
                parents[child.id] = node.id
                walk(child)
            }
        }
        for root in displayRoots { walk(root) }
        allNodes = nodes
        parentOf = parents
    }

    /// Snapshot roots with removal ghosts grafted back under their old
    /// parents, so outline and graph both show them in place.
    var displayRoots: [DeviceNode] {
        guard let snapshot else { return [] }
        var roots = snapshot.allRoots
        guard !ghostNodes.isEmpty else { return roots }
        func graft(_ node: DeviceNode) -> DeviceNode {
            var updated = node
            updated.children = node.children.map(graft)
            for ghost in ghostNodes where ghost.parentID == node.id
                && !node.children.contains(where: { $0.id == ghost.node.id }) {
                updated.children.append(ghost.node)
            }
            return updated
        }
        roots = roots.map(graft)
        return roots
    }

    var usbDisplayRoots: [DeviceNode] {
        displayRoots.filter { $0.kind == .usbController }
    }

    var tbDisplayRoots: [DeviceNode] {
        displayRoots.filter { $0.kind == .tbDomain }
    }

    var pciDisplayRoots: [DeviceNode] {
        displayRoots.filter { $0.kind == .pciDevice }
    }

    var systemDisplayNode: DeviceNode? {
        displayRoots.first { $0.kind == .system }
    }

    // MARK: Record mode

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        recordingStart = Date()
        sampleCount = 0
        series = [:]        // a new session must not inherit old sparklines/peaks
        totalSeries = []
        rates = [:]
        if sampler == nil {
            sampler = BandwidthSampler { rates, date in
                Task { @MainActor in AppStore.shared.ingest(rates: rates, at: date) }
            }
        }
        sampler?.start()
        if !bandwidthOverlay { bandwidthOverlay = true }
        appendEvent(EventRow(kind: .info, title: "Recording started", detail: "sampling real byte counters at 1 Hz"))
    }

    private func stopRecording() {
        isRecording = false
        sampler?.stop()
        rates = [:]
        appendEvent(EventRow(
            kind: .info,
            title: "Recording stopped",
            detail: "\(sampleCount) samples · series kept for inspection"
        ))
    }

    private func ingest(rates newRates: [UInt64: Double], at date: Date) {
        guard isRecording else { return }
        sampleCount += 1
        rates = newRates
        totalSeries.append(newRates.values.reduce(0, +))
        if totalSeries.count > 300 { totalSeries.removeFirst(totalSeries.count - 300) }
        // Every node with an active series gets a sample each tick (0 when
        // idle), so sparklines stay time-aligned.
        var updatedIDs = Set(series.keys)
        updatedIDs.formUnion(newRates.keys)
        for id in updatedIDs {
            var ring = series[id] ?? []
            ring.append(newRates[id] ?? 0)
            if ring.count > 300 { ring.removeFirst(ring.count - 300) }
            series[id] = ring
        }
    }

    /// Allocated share: this link's negotiated speed vs its parent link's —
    /// the registry-truth layer of the bandwidth overlay.
    func allocatedShare(of node: DeviceNode) -> Double? {
        guard node.linkSpeedBps > 0,
              let parentID = parentOf[node.id],
              let parent = allNodes[parentID],
              parent.linkSpeedBps > 0 else { return nil }
        return min(1.0, Double(node.linkSpeedBps) / Double(parent.linkSpeedBps))
    }

    /// Live utilization of a node's own link while recording.
    func utilization(of node: DeviceNode) -> Double? {
        guard isRecording, node.linkSpeedBps > 0, let rate = rates[node.id], rate > 0 else { return nil }
        return min(1.0, rate * 8 / Double(node.linkSpeedBps))
    }

    /// Busiest devices right now, for the traffic strip.
    var topTalkers: [(name: String, rate: Double, id: UInt64)] {
        rates.filter { $0.value > 1024 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { id, rate in allNodes[id].map { ($0.name, rate, id) } }
    }

    /// Headless screenshot support (`portree --export-screenshot`): capture a
    /// live snapshot, pick a visually rich selection, seed a couple of honest
    /// event rows so the composed panes aren't empty.
    func prepareHeadlessScreenshot() {
        apply(Snapshot.capture())
        selection = allNodes.values.first { $0.twin != nil }?.id
            ?? allNodes.values.first { $0.kind == .tbSwitch && parentOf[$0.id] != nil }?.id
            ?? allNodes.values.first?.id
        if let snapshot {
            appendEvent(EventRow(
                kind: .rescan,
                title: "Snapshot captured",
                detail: "\(snapshot.deviceCount) devices · \(snapshot.tbRoots.count) TB/USB4 domains · \(snapshot.pciRoots.count) PCIe roots"
            ))
        }
    }

    // MARK: Graph viewport

    func zoomAround(factor: CGFloat, anchor: CGPoint? = nil) {
        let oldZoom = zoom
        let newZoom = min(2.0, max(0.2, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        let pivot = anchor ?? CGPoint(x: lastViewport.width / 2, y: lastViewport.height / 2)
        // Keep the content point under `pivot` stationary while zooming.
        panOffset = CGSize(
            width: pivot.x - (pivot.x - panOffset.width) * (newZoom / oldZoom),
            height: pivot.y - (pivot.y - panOffset.height) * (newZoom / oldZoom)
        )
        zoom = newZoom
    }

    func fitGraph(contentSize: CGSize) {
        guard lastViewport.width > 50, contentSize.width > 0 else { return }
        let fitted = min(
            1.0,
            (lastViewport.width - 48) / contentSize.width,
            (lastViewport.height - 48) / contentSize.height
        )
        zoom = max(0.2, fitted)
        panOffset = CGSize(
            width: max(16, (lastViewport.width - contentSize.width * zoom) / 2),
            height: max(16, (lastViewport.height - contentSize.height * zoom) / 2)
        )
    }

    func centerGraph(on point: CGPoint) {
        panOffset = CGSize(
            width: lastViewport.width / 2 - point.x * zoom,
            height: lastViewport.height / 2 - point.y * zoom
        )
    }

    // MARK: Events

    private var lastRawDevice: (name: String, date: Date)?

    private func handleRaw(_ raw: [RawEvent]) {
        guard !logPaused else { return }
        for event in raw {
            let kind: EventRow.Kind = event.kind == .added ? .connected : .disconnected
            let deviceName = event.name.isEmpty ? event.className : event.name
            // Flood coalescing keys on the DEVICE, not kind+title: a flapping
            // device alternates connected/disconnected, and that alternation
            // is exactly the storm the ×N row exists for.
            if let last = lastRawDevice, last.name == deviceName,
               event.date.timeIntervalSince(last.date) < 3.0,
               var lastRow = events.last {
                lastRow.count += 1
                lastRow.date = event.date
                if lastRow.kind != kind {
                    lastRow = EventRow(
                        kind: .reenumerated,
                        title: "Flapping — \(deviceName)",
                        detail: "×\(lastRow.count) in <3 s — flaky link or power",
                        nodeID: kind == .connected ? event.entryID : nil,
                        date: event.date
                    )
                    lastRow.count = (events.last?.count ?? 1) + 1
                }
                events[events.count - 1] = lastRow
                lastRawDevice = (deviceName, event.date)
                continue
            }
            lastRawDevice = (deviceName, event.date)
            appendEvent(EventRow(
                kind: kind,
                title: "\(kind == .connected ? "Connected" : "Disconnected") — \(deviceName)",
                detail: event.isThunderbolt ? "Thunderbolt" : event.className,
                nodeID: kind == .connected ? event.entryID : nil,
                date: event.date
            ))
        }
    }

    func appendEvent(_ row: EventRow) {
        events.append(row)
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
        logWriter?.append(row)
    }

    func clearEvents() {
        events.removeAll()
    }

    var eventLogPath: String {
        logWriter?.fileURL.path ?? "(log file unavailable)"
    }

    // MARK: Actions

    func jump(to id: UInt64) {
        var cursor = parentOf[id]
        while let current = cursor {
            collapsed.remove(current)
            cursor = parentOf[current]
        }
        selection = id
        pendingScrollTarget = id
    }

    func toggleCollapsed(_ id: UInt64) {
        withAnimation(.snappy) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    func collapseAll() {
        withAnimation(.snappy) {
            collapsed = Set(allNodes.values.filter { !$0.children.isEmpty && parentOf[$0.id] != nil }.map(\.id))
        }
    }

    func expandAll() {
        withAnimation(.snappy) { collapsed.removeAll() }
    }

    func exportSnapshot() {
        guard let snapshot else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        do {
            let url = try Exporters.writeSnapshot(snapshot, to: downloads)
            appendEvent(EventRow(kind: .export, title: "Snapshot exported", detail: url.path))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            appendEvent(EventRow(kind: .info, title: "Export failed", detail: "\(error)"))
        }
    }

    // MARK: Search

    /// IDs matching the query, plus every ancestor (so the tree keeps shape).
    var searchResult: (matches: Set<UInt64>, visible: Set<UInt64>)? {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return nil }
        var matches: Set<UInt64> = []
        for node in allNodes.values {
            var haystack = "\(node.name) \(node.subtitle) \(node.className)"
            if let serial = node.serialNumber { haystack += " \(serial)" }
            if let vid = node.vendorID, let pid = node.productID {
                haystack += " \(Format.hex(vid, width: 4)):\(Format.hex(pid, width: 4))"
            }
            if haystack.lowercased().contains(query) { matches.insert(node.id) }
        }
        var visible = matches
        for id in matches {
            var cursor = parentOf[id]
            while let current = cursor {
                visible.insert(current)
                cursor = parentOf[current]
            }
        }
        return (matches, visible)
    }

    // MARK: Helpers

    private func expire(after seconds: Double, _ change: @escaping @MainActor (AppStore) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(.easeOut(duration: 0.4)) { change(self) }
        }
    }
}
