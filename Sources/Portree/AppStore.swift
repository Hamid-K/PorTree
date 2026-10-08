import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import notify
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
    /// A key in here means the node IS that screen.
    private(set) var displayModes: [UInt64: String] = [:]
    /// Dedicated nodes for registry display sinks that no topology node
    /// accounts for (plain-DP monitors behind TB→DP adapters), grafted under
    /// the switch that drives them — same mechanism as removal ghosts.
    private var sinkNodes: [(parentID: UInt64, node: DeviceNode)] = []

    /// Display-first categorization: a monitor with a built-in hub
    /// enumerates as a dock-category TB switch, but once a live screen is
    /// name-matched to the node, it IS a display — the hub is secondary
    /// (the card keeps a "hub" tag for it).
    func effectiveCategory(of node: DeviceNode) -> DeviceCategory {
        displayModes[node.id] != nil && node.kind != .system ? .display : node.category
    }

    /// Every screen the system is driving, for the sidebar Displays section —
    /// each bound to the graph node that is (or drives) it when known.
    struct DisplayEntry: Identifiable, Hashable {
        let id: UInt32          // CGDirectDisplayID
        let name: String
        let detail: String
        let nodeID: UInt64?
        let isBuiltIn: Bool
    }
    private(set) var displayEntries: [DisplayEntry] = []

    /// Transient spotlight: everything except this node fades out so a
    /// display picked in the sidebar is easy to spot in the graph.
    private(set) var focusedNodeID: UInt64?

    /// Floating link card: clicking an edge opens a popover with that
    /// connection's facts, anchored in CONTENT space so it pans/zooms with
    /// the graph. `childID` identifies the edge (every edge is its child).
    struct LinkSelection: Equatable {
        let childID: UInt64
    }
    var linkPopover: LinkSelection?

    /// Memoized layout: pan/zoom/hover change every frame but never the
    /// geometry, so the tree is rebuilt only when an input that actually
    /// shapes it changes.
    @ObservationIgnored private var layoutCacheKey: Int = 0
    @ObservationIgnored private var layoutCache: TreeLayout?

    func currentLayout() -> TreeLayout {
        // The key hashes the DERIVED per-node heights rather than trying to
        // enumerate every input of TagList.tags (rates, overlays, guard
        // flags, diff state, …) — any input that changes a card's height
        // changes the key by construction, so card frames and edge anchors
        // can never disagree. Heights iterate only the expanded cards;
        // recomputing them per body eval is trivial next to a layout build.
        let nodeHeights = TagMetrics.nodeHeights(store: self)
        var hasher = Hasher()
        hasher.combine(snapshot?.takenAt)
        hasher.combine(collapsed)
        hasher.combine(orientation)
        hasher.combine(ghostIDs)
        hasher.combine(sinkNodes.map(\.node.id))
        hasher.combine(sinkNodes.map(\.parentID))
        hasher.combine(nodeHeights)
        let key = hasher.finalize()
        if let cached = layoutCache, key == layoutCacheKey { return cached }
        let layout = TreeLayout(
            systemRoot: systemDisplayNode,
            usbRoots: usbDisplayRoots,
            tbRoots: tbDisplayRoots,
            pciRoots: pciDisplayRoots,
            collapsed: collapsed,
            orientation: orientation,
            nodeHeights: nodeHeights
        )
        layoutCache = layout
        layoutCacheKey = key
        return layout
    }

    // MARK: Cables & power (per-receptacle port-manager facts)

    /// The receptacle whose cable lands on this FIRST-HOP node (CIO UID ==
    /// the first TB/USB4 router's UID). Deeper hops return nil — their
    /// cables' eMarkers are not visible to the host's port manager.
    func portLink(for node: DeviceNode) -> PortLink? {
        guard node.kind == .tbSwitch,
              let uid = node.properties["UID"]?.intValue else { return nil }
        let unsigned = UInt64(bitPattern: uid)
        return snapshot?.portLinks.first { $0.cioUID == unsigned }
    }

    struct CableEntry: Identifiable, Hashable {
        let id: String
        let portLabel: String
        let detail: String
        let nodeID: UInt64?
        let active: Bool
        let powered: Bool
    }

    var cableEntries: [CableEntry] {
        (snapshot?.portLinks ?? []).map { link in
            var parts: [String] = []
            if let marker = link.eMarker {
                if let type = marker.productTypeDescription { parts.append(type.lowercased()) }
                if let speed = marker.ratedSpeed { parts.append(speed) }
                if let current = marker.ratedCurrent { parts.append(current) }
                if let construction = marker.construction { parts.append(construction) }
            } else if link.active {
                parts.append("no eMarker — legacy/unmarked cable")
            }
            if let contract = link.powerContract {
                parts.append("⚡ \(Format.milli(contract.voltageMV)) V in")
            }
            let nodeID = link.cioUID.flatMap { uid in
                allNodes.values.first {
                    $0.kind == .tbSwitch && $0.properties["UID"]?.intValue.map { UInt64(bitPattern: $0) } == uid
                }?.id
            }
            return CableEntry(
                id: link.id,
                portLabel: "\(link.portType) \(link.portNumber)",
                detail: link.active ? parts.joined(separator: " · ") : "empty",
                nodeID: nodeID,
                active: link.active,
                powered: link.powerContract != nil
            )
        }
    }

    struct PowerRow: Identifiable, Hashable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let nodeID: UInt64?
        let negotiated: Bool
    }

    var powerRows: [PowerRow] {
        guard let power = snapshot?.power else { return [] }
        var rows: [PowerRow] = []
        if power.externalConnected {
            let poweredPort = snapshot?.portLinks.first { $0.powerContract != nil }
            let sourceNode = poweredPort.flatMap { port in
                port.cioUID.flatMap { uid in
                    allNodes.values.first {
                        $0.kind == .tbSwitch && $0.properties["UID"]?.intValue.map { UInt64(bitPattern: $0) } == uid
                    }?.id
                }
            }
            var title = power.adapterDescription ?? "power source"
            if let watts = power.adapterWatts { title += " — \(watts) W" }
            var details: [String] = []
            if let port = poweredPort { details.append("\(port.portType) \(port.portNumber)") }
            if let contract = poweredPort?.powerContract {
                details.append("contract \(contract.label)")
            } else if let v = power.adapterVoltageMV, let a = power.adapterCurrentMA {
                details.append("contract \(Format.milli(v)) V · \(Format.milli(a)) A")
            }
            rows.append(PowerRow(
                id: "source", icon: "bolt.fill", title: title,
                detail: details.joined(separator: " · "),
                nodeID: sourceNode, negotiated: false
            ))
            if let inMW = power.systemPowerInMW {
                var detail = "live measured input"
                if let load = power.systemLoadMW { detail += " · system load \(String(format: "%.1f", Double(load) / 1000)) W" }
                rows.append(PowerRow(
                    id: "live", icon: "gauge.with.dots.needle.33percent",
                    title: "drawing \(String(format: "%.1f", Double(inMW) / 1000)) W now",
                    detail: detail, nodeID: nil, negotiated: false
                ))
            }
            for (index, pdo) in power.hvcMenu.enumerated() {
                rows.append(PowerRow(
                    id: "pdo\(index)", icon: "list.bullet",
                    title: pdo.label,
                    detail: power.hvcIndex == Int64(index) ? "negotiated" : "offered",
                    nodeID: nil, negotiated: power.hvcIndex == Int64(index)
                ))
            }
        } else {
            rows.append(PowerRow(
                id: "battery", icon: "battery.75percent", title: "On battery",
                detail: "no external power source", nodeID: nil, negotiated: false
            ))
        }
        return rows
    }

    func focusNode(_ id: UInt64) {
        selection = id
        pendingScrollTarget = id
        withAnimation(.easeOut(duration: 0.25)) { focusedNodeID = id }
        expire(after: 3.0) { if $0.focusedNodeID == id { $0.focusedNodeID = nil } }
    }
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
    var legendShown = true { didSet { persist(legendShown, "view.legend2") } }
    /// Bandwidth overlay (allocated share + live rates) — OFF by default,
    /// deliberately not persisted.
    var bandwidthOverlay = false
    /// Mint power-allocation sparkline inside cards while recording — OFF by
    /// default (the mA number chip is always shown regardless).
    var powerOverlay = false
    /// Connection beeps: Pop/Bottle on plug/unplug, Basso on alerts, Sosumi
    /// on unknown devices.
    var soundsEnabled = true { didSet { persist(soundsEnabled, "sounds") } }
    /// Device guard: flag devices never seen on this Mac before. The first
    /// run with the guard on learns everything currently attached as the
    /// trusted baseline.
    var deviceGuard = true {
        didSet {
            persist(deviceGuard, "security.guard")
            if deviceGuard { updateDeviceGuard(alerting: true) } else { untrustedIDs = [] }
        }
    }
    /// Connected devices the trust store has never seen (red-flagged until
    /// trusted or detached).
    private(set) var untrustedIDs: Set<UInt64> = []
    private let trustStore = TrustStore(fileURL: TrustStore.defaultFileURL())

    var knownDeviceCount: Int { trustStore.devices.count }

    /// Live Σ of a hub/controller subtree's counter-bearing devices.
    func aggregateRate(for node: DeviceNode) -> Double {
        node.flattened().compactMap { rates[$0.id] }.reduce(0, +)
    }
    /// Sidebar presentation: the topology tree, or a flat device-type filter
    /// where picking a row spotlights the device in the graph.
    enum SidebarMode: String, CaseIterable {
        case topology, types
        var label: String { self == .topology ? "Tree" : "Types" }
    }
    var sidebarMode: SidebarMode = .topology {
        didSet { persist(sidebarMode.rawValue, "view.sidebarMode") }
    }
    var orientation: LayoutOrientation = .leftToRight {
        didSet { persist(orientation.rawValue, "view.orientation") }
    }
    var canvasBackground: CanvasBackground = .system {
        didSet { persist(canvasBackground.rawValue, "view.background") }
    }
    var appearance: AppAppearance = .system {
        didSet { persist(appearance.rawValue, "view.appearance") }
    }
    /// UI font scale (0.85–1.3 — fixed card frames cap the useful range).
    var fontScale: CGFloat = 1.0 {
        didSet { persist(Double(fontScale), "view.fontScale") }
    }

    func adjustFontScale(by step: CGFloat) {
        withAnimation(.snappy) {
            fontScale = min(1.3, max(0.85, ((fontScale + step) * 20).rounded() / 20))
        }
    }

    func resetFontScale() {
        withAnimation(.snappy) { fontScale = 1.0 }
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
            // Fresh key: the legend chrome was rebuilt, old persisted "off"
            // states are deliberately not carried over.
            legendShown = defaults.object(forKey: "portree.view.legend2") as? Bool ?? true
        }
        if let raw = defaults.string(forKey: "portree.view.orientation"),
           let restored = LayoutOrientation(rawValue: raw) {
            orientation = restored
        }
        if let raw = defaults.string(forKey: "portree.view.background"),
           let restored = CanvasBackground(rawValue: raw) {
            canvasBackground = restored
        }
        let storedScale = defaults.double(forKey: "portree.view.fontScale")
        if storedScale > 0 { fontScale = CGFloat(storedScale) }
        if let raw = defaults.string(forKey: "portree.view.appearance"),
           let restored = AppAppearance(rawValue: raw) {
            appearance = restored
        }
        soundsEnabled = defaults.object(forKey: "portree.sounds") as? Bool ?? true
        deviceGuard = defaults.object(forKey: "portree.security.guard") as? Bool ?? true
        if let raw = defaults.string(forKey: "portree.view.sidebarMode"),
           let restored = SidebarMode(rawValue: raw) {
            sidebarMode = restored
        }
    }

    private func playSound(_ name: String) {
        guard soundsEnabled else { return }
        NSSound(named: name)?.play()
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

        // Display config changes (a plain-DP/HDMI monitor plugged into an
        // adapter raises no USB/TB hotplug event) → rescan so sink nodes
        // and mode chips stay current. The notification fires in bursts
        // (resolution negotiation, profile updates), so coalesce here —
        // rescanSilently() bypasses HotplugMonitor's own debounce.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppStore.shared.scheduleScreenRescan() }
        }

        // Power-source changes (a pure PD charger or MagSafe raises no
        // USB/TB/display event at all) — kIOPSNotifyPowerSource via notify(3).
        var token: Int32 = 0
        notify_register_dispatch("com.apple.system.powersources.source", &token, DispatchQueue.main) { _ in
            Task { @MainActor in AppStore.shared.scheduleScreenRescan() }
        }
    }

    private var screenRescanPending = false

    private func scheduleScreenRescan() {
        guard !screenRescanPending else { return }
        screenRescanPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.screenRescanPending = false
            self.rescanSilently()
        }
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
                // A departed ghost can unblock sink attribution (it was an
                // egress candidate while grafted) — recompute, don't wait
                // for an unrelated snapshot.
                $0.updateDisplayModes()
            }
        }

        // Arrivals: glow briefly. A keyboard-class arrival additionally
        // raises an alert — anything that can type deserves a second look
        // (re-plugs of a known identity collapsed into re-enumerations above
        // and never reach this loop).
        for id in arrivals {
            arrivalIDs.insert(id)
            expire(after: 1.6) { $0.arrivalIDs.remove(id) }
            if let node = newByID[id], node.hasKeyboardInterface {
                appendEvent(EventRow(
                    kind: .alert,
                    title: "New keyboard-class device — \(node.name)",
                    detail: "this device can inject keystrokes — unplug it if you don't recognize it",
                    nodeID: id
                ))
                playSound("Basso")
            }
        }

        withAnimation(.spring(duration: 0.35)) {
            previousSnapshot = new
            snapshot = new
            lastRefresh = new.takenAt
            reindex()
        }

        issues = Doctor.diagnose(snapshot: new)
        updateDeviceGuard(alerting: true)
        recomputeBaselineDiff()
        updateDisplayModes()
        updateCameraInfo()

        // A link card for a connection that no longer exists closes itself.
        if let popover = linkPopover, allNodes[popover.childID] == nil {
            linkPopover = nil
        }

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

    // MARK: Device guard

    /// Wholesale re-evaluation against the trust store: flags EVERY connected
    /// unknown device, not just fresh arrivals — a device attached while the
    /// app was closed is caught on the first snapshot after launch.
    private func updateDeviceGuard(alerting: Bool) {
        guard deviceGuard, let snapshot else {
            untrustedIDs = []
            return
        }
        if !trustStore.hasBaseline {
            // First run: everything attached right now becomes the baseline.
            let learned = trustStore.learn(from: snapshot)
            appendEvent(EventRow(
                kind: .info,
                title: "Device guard baseline learned",
                detail: "\(learned) attached devices trusted — anything new will be flagged"
            ))
            return
        }
        var flagged: Set<UInt64> = []
        for root in snapshot.usbRoots + snapshot.tbRoots {
            for node in root.flattened()
            where (node.kind == .usbDevice || node.kind == .tbSwitch)
                && node.deviceIdentity != nil
                && !trustStore.isKnown(node) {
                flagged.insert(node.id)
            }
        }
        let newFlags = flagged.subtracting(untrustedIDs)
        untrustedIDs = flagged
        guard alerting, !newFlags.isEmpty else { return }
        for id in newFlags {
            let name = allNodes[id]?.name ?? "device \(id)"
            appendEvent(EventRow(
                kind: .alert,
                title: "UNKNOWN DEVICE — \(name)",
                detail: "never seen on this Mac before — right-click the node to trust it",
                nodeID: id
            ))
        }
        playSound("Sosumi")
    }

    func isUntrusted(_ id: UInt64) -> Bool { untrustedIDs.contains(id) }

    func trustDevice(_ node: DeviceNode) {
        let added = trustStore.trust(node)
        guard added || untrustedIDs.contains(node.id) else { return }
        trustStore.save()
        withAnimation(.easeOut(duration: 0.3)) { _ = untrustedIDs.remove(node.id) }
        appendEvent(EventRow(kind: .info, title: "Trusted — \(node.name)", detail: "added to known devices", nodeID: node.id))
    }

    func trustAllConnected() {
        guard let snapshot else { return }
        let added = trustStore.learn(from: snapshot)
        withAnimation(.easeOut(duration: 0.3)) { untrustedIDs = [] }
        appendEvent(EventRow(
            kind: .info,
            title: "Trusted all connected devices",
            detail: added == 0 ? "no new devices to add" : "\(added) new device\(added == 1 ? "" : "s") added to known devices"
        ))
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

    /// Snapshot roots with removal ghosts and synthesized display-sink nodes
    /// grafted under their parents, so outline and graph both show them in
    /// place.
    var displayRoots: [DeviceNode] {
        guard let snapshot else { return [] }
        var roots = snapshot.allRoots
        let extras = ghostNodes + sinkNodes
        guard !extras.isEmpty else { return roots }
        func graft(_ node: DeviceNode) -> DeviceNode {
            var updated = node
            updated.children = node.children.map(graft)
            for extra in extras where extra.parentID == node.id
                && !node.children.contains(where: { $0.id == extra.node.id }) {
                updated.children.append(extra.node)
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
                playSound("Basso")
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
    func prepareHeadlessScreenshot(using snapshot: Snapshot? = nil) {
        apply(snapshot ?? Snapshot.capture())
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
        var sawConnect = false
        var sawDisconnect = false
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
            if kind == .connected { sawConnect = true } else { sawDisconnect = true }
            appendEvent(EventRow(
                kind: kind,
                title: "\(kind == .connected ? "Connected" : "Disconnected") — \(deviceName)",
                detail: event.isThunderbolt ? "Thunderbolt" : event.className,
                nodeID: kind == .connected ? event.entryID : nil,
                date: event.date
            ))
        }
        // One beep per batch per direction — a dock enumerating ten devices
        // is one plug, not ten.
        if sawConnect { playSound("Pop") }
        if sawDisconnect { playSound("Bottle") }
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

    /// Expand every card whose tags actually overflow the compact row.
    func expandAllTags() {
        withAnimation(.snappy) {
            for node in allNodes.values {
                let tags = TagList.tags(node: node, store: self, verbose: false)
                if tags.count > TagMetrics.fittingPrefix(tags, scale: fontScale) {
                    expandedTags.insert(node.id)
                }
            }
        }
    }

    func collapseAllTags() {
        withAnimation(.snappy) { expandedTags.removeAll() }
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
        var nodeForScreen: [CGDirectDisplayID: UInt64] = [:]

        // Registry DP sinks join to CG screens by EDID identity (vendor/
        // product/serial), never by name — the sink carries the negotiated
        // DP link rate the CG side doesn't know. Sinks ride the snapshot,
        // captured on the IOKit queue: no registry I/O on the MainActor.
        let sinks = (snapshot?.displaySinks ?? []).filter(\.active)
        func sink(for displayID: CGDirectDisplayID) -> DisplaySink? {
            sinks.first {
                $0.edidProductID == Int64(CGDisplayModelNumber(displayID))
                    && ($0.edidSerial == nil || $0.edidSerial == Int64(CGDisplaySerialNumber(displayID)))
            }
        }

        func mode(of screen: NSScreen) -> (id: CGDirectDisplayID, text: String)? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            var text = "\(mode.pixelWidth)×\(mode.pixelHeight)"
            if mode.refreshRate > 0 { text += String(format: " @ %.0f Hz", mode.refreshRate) }
            return (displayID, text)
        }

        // External displays we actually have nodes for, name-matched to
        // NSScreen. ANY topology node category qualifies — a monitor with a
        // built-in hub (Dell U-series) enumerates as a dock-category TB
        // switch, not as a pure display. Synthesized sink nodes are excluded:
        // a sink card matching its own screen here would un-orphan the sink
        // and tear its card down on the next pass (period-2 flicker).
        for node in allNodes.values.sorted(by: { $0.id < $1.id })
        where node.kind != .system && node.kind != .displaySink {
            let nodeName = node.name.lowercased()
            guard nodeName.count >= 4,
                  let screen = NSScreen.screens.first(where: {
                      let screenName = $0.localizedName.lowercased()
                      return screenName.contains(nodeName) || nodeName.contains(screenName)
                  }),
                  let current = mode(of: screen),
                  !matchedScreens.contains(current.id) else { continue }
            matchedScreens.insert(current.id)
            let connection = node.isDisplayLink
                ? "USB · DisplayLink"
                : (node.kind == .tbSwitch ? "DisplayPort · TB/USB4 tunnel" : "DisplayPort")
            let rate = sink(for: current.id)?.linkRate.map { " · \($0)" } ?? ""
            result[node.id] = "\(current.text) · \(connection)\(rate)"
            nodeForScreen[current.id] = node.id
        }

        // The built-in panel has no USB/TB/PCI node — it belongs to the SoC.
        if let system = systemDisplayNode {
            for screen in NSScreen.screens {
                guard let current = mode(of: screen),
                      !matchedScreens.contains(current.id),
                      CGDisplayIsBuiltin(current.id) != 0 else { continue }
                result[system.id] = "\(current.text) · internal"
                nodeForScreen[current.id] = system.id
                break
            }
        }

        // Sinks not accounted for by a matched node become DEDICATED display
        // nodes: a plain-DP monitor behind a TB→DP adapter is a real registry
        // entry (IOPortTransportStateDisplayPort, its own entry ID) — it
        // deserves a card, not a chip on someone else's card.
        //
        // A sink whose EDID joins a screen that already name-matched a node
        // (a hub-monitor like the U2725QE: the sink IS that node's panel)
        // gets no extra node. The rest are grafted under the TB switch that
        // provably drives them: egress candidates are switches with used DP
        // outputs, minus one output for a switch that is itself a matched
        // display (its own panel consumes one). Attribution happens only
        // when exactly one candidate has spare used outputs — never a guess.
        // Orphan = an active sink no topology node accounts for: its screen
        // didn't match a node, AND no topology node carries its EDID name
        // (a mirrored or lid-managed hub monitor has no NSScreen but is
        // still its own switch's panel — never give it a duplicate card).
        var orphanSinks: [DisplaySink] = []
        for sink in sinks {
            let joinedScreenID = NSScreen.screens.compactMap { mode(of: $0)?.id }.first {
                sink.edidProductID == Int64(CGDisplayModelNumber($0))
                    && (sink.edidSerial == nil || sink.edidSerial == Int64(CGDisplaySerialNumber($0)))
            }
            if let joinedScreenID, nodeForScreen[joinedScreenID] != nil { continue }
            let sinkName = sink.name.lowercased()
            let ownedByNode = allNodes.values.contains { node in
                node.kind != .displaySink && node.name.count >= 4
                    && (sinkName.contains(node.name.lowercased()) || node.name.lowercased().contains(sinkName))
            }
            if ownedByNode { continue }
            orphanSinks.append(sink)
        }

        var grafts: [(parentID: UInt64, node: DeviceNode)] = []
        func makeSinkNode(_ sink: DisplaySink, subtitle: String) -> DeviceNode {
            DeviceNode(
                id: sink.registryID,
                kind: .displaySink,
                name: sink.name,
                subtitle: subtitle,
                className: "IOPortTransportStateDisplayPort",
                category: .display,
                tier: .infrastructure,
                speedLabel: sink.linkRate ?? "",
                linkSpeedBps: 0,
                properties: sink.properties
            )
        }
        func annotate(_ sink: DisplaySink, node: DeviceNode, via: String) {
            // Mode chips + sidebar spotlight route to the new node. Each
            // screen is claimed once — two serial-less same-model monitors
            // must not both join the first screen.
            guard let current = NSScreen.screens.compactMap(mode(of:)).first(where: { c in
                nodeForScreen[c.id] == nil
                    && sink.edidProductID == Int64(CGDisplayModelNumber(c.id))
                    && (sink.edidSerial == nil || sink.edidSerial == Int64(CGDisplaySerialNumber(c.id)))
            }) else { return }
            let rate = sink.linkRate.map { " · \($0)" } ?? ""
            result[node.id] = "\(current.text) · \(sink.downstreamType ?? "DisplayPort") · \(via)\(rate)"
            nodeForScreen[current.id] = node.id
        }

        // Non-tunneled sinks are built-in ports (HDMI on Mac mini/MBP) — the
        // registry itself says they can't be behind a TB device. They belong
        // to the SoC node.
        let builtInSinks = orphanSinks.filter { !$0.tunneled }
        if let system = systemDisplayNode {
            for sink in builtInSinks {
                let node = makeSinkNode(sink, subtitle: "\(sink.downstreamType ?? "DisplayPort") sink · built-in port")
                grafts.append((parentID: system.id, node: node))
                annotate(sink, node: node, via: "built-in port")
            }
        }

        // Tunneled sinks attach under the TB switch that provably drives
        // them: the only live (non-ghost) switch with spare used DP outputs,
        // after deducting one output for a switch that is itself a matched
        // display (its own panel). Never a guess — ambiguity means the sink
        // stays sidebar-only.
        let tunneledSinks = orphanSinks.filter(\.tunneled)
        if !tunneledSinks.isEmpty {
            let egress = allNodes.values
                .filter { $0.kind == .tbSwitch && !ghostIDs.contains($0.id) }
                .map { node -> (id: UInt64, spare: Int64) in
                    let used = node.dpOutUsed ?? 0
                    let ownPanel: Int64 = result[node.id] != nil ? 1 : 0
                    return (node.id, max(0, used - ownPanel))
                }
                .filter { $0.spare > 0 }
            if egress.count == 1, let host = egress.first, host.spare >= Int64(tunneledSinks.count) {
                for sink in tunneledSinks {
                    let node = makeSinkNode(sink, subtitle: "\(sink.downstreamType ?? "DisplayPort") sink · TB/USB4 tunnel")
                    grafts.append((parentID: host.id, node: node))
                    annotate(sink, node: node, via: "via adapter")
                }
            }
        }

        displayModes = result
        let graftsChanged = !grafts.elementsEqual(sinkNodes) {
            $0.parentID == $1.parentID && $0.node == $1.node
        }
        sinkNodes = grafts
        displayEntries = NSScreen.screens.compactMap { screen in
            guard let current = mode(of: screen) else { return nil }
            let builtIn = CGDisplayIsBuiltin(current.id) != 0
            let rate = sink(for: current.id)?.linkRate.map { " · \($0)" } ?? ""
            return DisplayEntry(
                id: current.id,
                name: screen.localizedName,
                detail: "\(current.text)\(builtIn ? " · internal" : rate)",
                nodeID: nodeForScreen[current.id],
                isBuiltIn: builtIn
            )
        }

        // Synthesized nodes changed → the graft and every index must agree.
        if graftsChanged { reindex() }
    }

    // MARK: Web identification

    /// Open the default browser searching for this device's raw identity —
    /// the lsusb-style vid:pid pair is the most-indexed token on the web,
    /// backed by the product/vendor strings.
    func searchWeb(for node: DeviceNode) {
        var terms: [String] = []
        if let vid = node.vendorID, let pid = node.productID {
            terms.append(String(format: "%04llx:%04llx", vid, pid))
            terms.append("USB")
        }
        if node.kind == .tbSwitch {
            terms.append("Thunderbolt")
            if let vid = node.properties["Device Vendor ID"]?.intValue,
               let did = node.properties["Device Model ID"]?.intValue {
                terms.append(String(format: "%04llx:%04llx", vid, did))
            }
        }
        terms.append("\"\(node.name)\"")
        let query = terms.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
        appendEvent(EventRow(kind: .info, title: "Web search opened", detail: query, nodeID: node.id))
    }

    /// Raw USB packet capture does not exist on modern macOS (the XHC20 tap
    /// died with Catalina and never reached Apple Silicon) — the working path
    /// is usbmon inside a Linux VM with the device passed through, or a
    /// hardware analyzer. This puts the complete, device-prefiltered recipe
    /// on the clipboard so the knowledge gap isn't the blocker.
    func copyCaptureRecipe(for node: DeviceNode) {
        let vid = node.vendorID.map { String(format: "0x%04llx", $0) } ?? "0x????"
        let pid = node.productID.map { String(format: "0x%04llx", $0) } ?? "0x????"
        let recipe = """
        # Raw USB capture for: \(node.name) (\(vid):\(pid))
        #
        # macOS has no software USB tap (XHC20 was removed in Catalina; none on
        # Apple Silicon). Two working options:
        #
        # OPTION A — Linux VM with USB passthrough (UTM / VMware Fusion):
        #   1. Attach "\(node.name)" to the VM (USB passthrough).
        #   2. In the guest:
        #        sudo modprobe usbmon
        #        sudo wireshark            # capture on usbmonX (X = bus number)
        #   3. Wireshark display filter for just this device:
        #        usb.idVendor == \(vid) && usb.idProduct == \(pid)
        #      ...or after noting the device address on the bus:
        #        usb.device_address == <addr>
        #   CLI equivalent:
        #        sudo tshark -i usbmon1 -Y 'usb.idVendor == \(vid) && usb.idProduct == \(pid)' -w capture.pcapng
        #
        # OPTION B — hardware analyzer (Total Phase Beagle, OpenVizsla):
        #   inline between host and device; full-speed-accurate, no OS limits.
        #
        # What PorTree can watch natively instead: enumeration events, port
        # error counters, throughput counters (storage/network), power
        # allocation, overcurrent alerts — all in record mode.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recipe, forType: .string)
        appendEvent(EventRow(kind: .info, title: "Capture recipe copied", detail: "\(node.name) · \(vid):\(pid)", nodeID: node.id))
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
