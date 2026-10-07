import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
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
    /// Live display mode per display node ("3840×2160 @ 120 Hz · DisplayPort
    /// · TB/USB4 tunnel"), matched via NSScreen names + CoreGraphics modes.
    private(set) var displayModes: [UInt64: String] = [:]
    /// Camera capability per video node ("up to 1920×1080 @ 60 fps · UVC"),
    /// matched by the VID/PID AVCaptureDevice.modelID carries; `inUse` means
    /// another app is streaming from it right now.
    private(set) var cameraInfo: [UInt64: (text: String, inUse: Bool)] = [:]

    // Transient presentation state
    private(set) var ghostIDs: Set<UInt64> = []
    private(set) var arrivalIDs: Set<UInt64> = []
    private(set) var reenumeratedIDs: Set<UInt64> = []
    private var ghostNodes: [(parentID: UInt64, node: DeviceNode)] = []

    // MARK: UI state (viewport-ish state persists across launches)
    var selection: UInt64?
    var collapsed: Set<UInt64> = []
    var searchText = "" {
        didSet { searchCursor = 0 }
    }
    var inspectorShown = true { didSet { persist(inspectorShown, "view.inspector") } }
    var drawerShown = true { didSet { persist(drawerShown, "view.drawer") } }
    var logPaused = false
    var zoom: CGFloat = 1.0 { didSet { persist(Double(zoom), "view.zoom") } }
    var pendingScrollTarget: UInt64?
    var toolboxShown = false
    /// Cards whose tag row is expanded to the full wrapped list (+N pill).
    var expandedTags: Set<UInt64> = []
    /// Persistent legend overlay in the graph corner (palette button toggles).
    var legendShown = true { didSet { persist(legendShown, "view.legend") } }
    /// Bandwidth overlay (allocated share + live rates) — OFF by default,
    /// deliberately not persisted.
    var bandwidthOverlay = false
    /// Mint power-allocation sparkline inside cards while recording — OFF by
    /// default (the mA number chip is always shown regardless).
    var powerOverlay = false

    /// Live Σ of a hub/controller subtree's counter-bearing devices.
    func aggregateRate(for node: DeviceNode) -> Double {
        node.flattened().compactMap { rates[$0.id] }.reduce(0, +)
    }
    var orientation: LayoutOrientation = .leftToRight {
        didSet { persist(orientation.rawValue, "view.orientation") }
    }
    var canvasBackground: CanvasBackground = .system {
        didSet { persist(canvasBackground.rawValue, "view.background") }
    }
    /// Graph pan offset in viewport points (content is scaled by `zoom`).
    var panOffset: CGSize = CGSize(width: 24, height: 24) {
        didSet {
            persist(Double(panOffset.width), "view.panX")
            persist(Double(panOffset.height), "view.panY")
        }
    }
    /// Last known graph viewport, for fit/zoom-around-center math.
    var lastViewport: CGSize = .zero

    private var restoringState = false
    private var searchCursor = 0

    private init() {
        restoreViewState()
    }

    private func persist(_ value: Any, _ key: String) {
        guard !restoringState else { return }
        UserDefaults.standard.set(value, forKey: "portree.\(key)")
    }

    private func restoreViewState() {
        restoringState = true
        defer { restoringState = false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "portree.view.zoom") != nil {
            zoom = CGFloat(defaults.double(forKey: "portree.view.zoom"))
            panOffset = CGSize(
                width: defaults.double(forKey: "portree.view.panX"),
                height: defaults.double(forKey: "portree.view.panY")
            )
            inspectorShown = defaults.object(forKey: "portree.view.inspector") as? Bool ?? true
            drawerShown = defaults.object(forKey: "portree.view.drawer") as? Bool ?? true
            legendShown = defaults.object(forKey: "portree.view.legend") as? Bool ?? true
        }
        if let raw = defaults.string(forKey: "portree.view.orientation"),
           let restored = LayoutOrientation(rawValue: raw) {
            orientation = restored
        }
        if let raw = defaults.string(forKey: "portree.view.background"),
           let restored = CanvasBackground(rawValue: raw) {
            canvasBackground = restored
        }
    }

    // MARK: Record mode (live throughput; real counters only)
    private(set) var isRecording = false
    private(set) var recordingStart: Date?
    private(set) var rates: [UInt64: Double] = [:]      // bytes/sec, current
    private(set) var series: [UInt64: [Double]] = [:]   // ring, 300 samples
    private(set) var totalSeries: [Double] = []         // aggregate, for the traffic strip
    /// Power-allocation history per node (mA) — steps on renegotiation.
    private(set) var powerSeries: [UInt64: [Double]] = [:]
    private(set) var currentPowerMA: [UInt64: Int64] = [:]
    /// Nodes whose kernel overcurrent counter incremented during this
    /// recording — actual detected overdraw, flashed red.
    private(set) var overdriveIDs: Set<UInt64> = []
    private var lastOvercurrent: [UInt64: Int64] = [:]
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
        recomputeBaselineDiff()
        updateDisplayModes()
        updateCameraInfo()

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
        powerSeries = [:]
        currentPowerMA = [:]
        lastOvercurrent = [:]
        overdriveIDs = []
        if sampler == nil {
            sampler = BandwidthSampler { rates, power, date in
                Task { @MainActor in AppStore.shared.ingest(rates: rates, power: power, at: date) }
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

    private func ingest(rates newRates: [UInt64: Double], power: BandwidthSampler.PowerSample, at date: Date) {
        guard isRecording else { return }
        sampleCount += 1
        rates = newRates
        totalSeries.append(newRates.values.reduce(0, +))
        if totalSeries.count > 300 { totalSeries.removeFirst(totalSeries.count - 300) }

        // Power: allocation history per node + overcurrent-counter deltas.
        currentPowerMA = power.allocationMA
        for (id, ma) in power.allocationMA {
            var ring = powerSeries[id] ?? []
            ring.append(Double(ma))
            if ring.count > 300 { ring.removeFirst(ring.count - 300) }
            powerSeries[id] = ring
        }
        for (id, count) in power.overcurrentCount {
            if let previous = lastOvercurrent[id], count > previous {
                overdriveIDs.insert(id)
                let name = allNodes[id]?.name ?? "device \(id)"
                appendEvent(EventRow(
                    kind: .alert,
                    title: "OVERCURRENT — \(name)",
                    detail: "kernel overcurrent counter incremented (now \(count)) — the device drew more than the port could deliver",
                    nodeID: id,
                    date: date
                ))
                expire(after: 6.0) { $0.overdriveIDs.remove(id) }
            }
            lastOvercurrent[id] = count
        }
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

    func toggleTagExpansion(_ id: UInt64) {
        withAnimation(.snappy) {
            if expandedTags.contains(id) { expandedTags.remove(id) } else { expandedTags.insert(id) }
        }
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

    // MARK: Display modes (resolution / refresh / connection)

    private func updateDisplayModes() {
        var result: [UInt64: String] = [:]
        var matchedScreens: Set<CGDirectDisplayID> = []

        func mode(of screen: NSScreen) -> (id: CGDirectDisplayID, text: String)? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            var text = "\(mode.pixelWidth)×\(mode.pixelHeight)"
            if mode.refreshRate > 0 { text += String(format: " @ %.0f Hz", mode.refreshRate) }
            return (displayID, text)
        }

        // External displays we actually have nodes for: TB/USB4 monitors
        // (DP-IN switches) and DisplayLink devices. Name-matched to NSScreen.
        for node in allNodes.values where node.category == .display || node.isDisplayLink {
            let nodeName = node.name.lowercased()
            guard nodeName.count >= 4,
                  let screen = NSScreen.screens.first(where: {
                      let screenName = $0.localizedName.lowercased()
                      return screenName.contains(nodeName) || nodeName.contains(screenName)
                  }),
                  let current = mode(of: screen) else { continue }
            matchedScreens.insert(current.id)
            let connection = node.isDisplayLink
                ? "USB · DisplayLink"
                : (node.kind == .tbSwitch ? "DisplayPort · TB/USB4 tunnel" : "DisplayPort")
            result[node.id] = "\(current.text) · \(connection)"
        }

        // The built-in panel has no USB/TB/PCI node — it belongs to the SoC.
        if let system = systemDisplayNode {
            let builtIn = NSScreen.screens.compactMap { screen -> String? in
                guard let current = mode(of: screen),
                      !matchedScreens.contains(current.id),
                      CGDisplayIsBuiltin(current.id) != 0 else { return nil }
                return "\(current.text) · internal"
            }
            if let first = builtIn.first { result[system.id] = first }
        }

        displayModes = result
    }

    // MARK: Camera capability (UVC format list via AVFoundation — generic:
    // enumeration needs no TCC consent; only actual capture would)

    private func updateCameraInfo() {
        var result: [UInt64: (text: String, inUse: Bool)] = [:]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices

        var claimed: Set<UInt64> = []
        for camera in devices {
            // modelID carries identity generically: "UVC Camera VendorID_1133 ProductID_2142"
            guard let vid = parse(camera.modelID, after: "VendorID_"),
                  let pid = parse(camera.modelID, after: "ProductID_") else { continue }
            guard let node = allNodes.values.first(where: {
                !claimed.contains($0.id) && $0.vendorID == vid && $0.productID == pid
            }) else { continue }
            claimed.insert(node.id)

            // Best capability across the advertised UVC formats.
            var bestArea: Int32 = 0
            var best: (w: Int32, h: Int32, fps: Double)?
            for format in camera.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                if dims.width * dims.height > bestArea
                    || (dims.width * dims.height == bestArea && fps > (best?.fps ?? 0)) {
                    bestArea = dims.width * dims.height
                    best = (dims.width, dims.height, fps)
                }
            }
            guard let best else { continue }
            let inUse = camera.isInUseByAnotherApplication
            result[node.id] = (
                String(format: "up to %d×%d @ %.0f fps · UVC", best.w, best.h, best.fps),
                inUse
            )
        }
        cameraInfo = result
    }

    private func parse(_ text: String, after marker: String) -> Int64? {
        guard let range = text.range(of: marker) else { return nil }
        return Int64(text[range.upperBound...].prefix(while: \.isNumber))
    }

    // MARK: Baseline diff (capture/load a frozen state, compare against live)

    private(set) var baseline: Snapshot?
    private(set) var baselineDiff: BaselineDiff?

    func captureBaseline() {
        guard let snapshot else { return }
        baseline = snapshot
        recomputeBaselineDiff()
        appendEvent(EventRow(kind: .info, title: "Baseline captured", detail: "\(snapshot.deviceCount) devices frozen for comparison"))
    }

    func clearBaseline() {
        baseline = nil
        baselineDiff = nil
    }

    func saveBaseline() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "portree-baseline.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporters.json(snapshot).write(to: url)
            appendEvent(EventRow(kind: .export, title: "Baseline saved", detail: url.path))
        } catch {
            appendEvent(EventRow(kind: .info, title: "Baseline save failed", detail: "\(error)"))
        }
    }

    func loadBaseline() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            baseline = try decoder.decode(Snapshot.self, from: Data(contentsOf: url))
            recomputeBaselineDiff()
            appendEvent(EventRow(
                kind: .info,
                title: "Baseline loaded",
                detail: "\(url.lastPathComponent) · \(baseline?.deviceCount ?? 0) devices"
            ))
        } catch {
            appendEvent(EventRow(kind: .info, title: "Baseline load failed", detail: "\(error)"))
        }
    }

    func recomputeBaselineDiff() {
        guard let baseline, let snapshot else {
            baselineDiff = nil
            return
        }
        baselineDiff = BaselineDiff.compare(baseline: baseline, current: snapshot)
    }

    /// Matches in stable (name) order for ⌘G cycling.
    var searchOrderedHits: [UInt64] {
        guard let result = searchResult else { return [] }
        return result.matches.sorted { (allNodes[$0]?.name ?? "") < (allNodes[$1]?.name ?? "") }
    }

    func nextSearchHit() {
        let hits = searchOrderedHits
        guard !hits.isEmpty else { return }
        jump(to: hits[searchCursor % hits.count])
        searchCursor += 1
    }

    // MARK: Helpers

    private func expire(after seconds: Double, _ change: @escaping @MainActor (AppStore) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(.easeOut(duration: 0.4)) { change(self) }
        }
    }
}
