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

        // Re-enumerations: one amber presentation, not ghost + new node.
        for item in diff.reenumerated {
            reenumeratedIDs.insert(item.newID)
            appendEvent(EventRow(
                kind: .reenumerated,
                title: "Re-enumerated — \(item.oldNode.name)",
                detail: item.confident ? "same identity, new session" : "identity match low-confidence (no serial)",
                nodeID: item.newID
            ))
            expire(after: 2.5) { $0.reenumeratedIDs.remove(item.newID) }
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
            }
        }

        // Arrivals: glow briefly.
        for id in diff.addedIDs {
            arrivalIDs.insert(id)
            expire(after: 1.6) { $0.arrivalIDs.remove(id) }
        }

        withAnimation(.spring(duration: 0.35)) {
            previousSnapshot = new
            snapshot = new
            lastRefresh = new.takenAt
            reindex()
        }

        if selection == nil {
            selection = new.allRoots.first?.children.first?.id ?? new.allRoots.first?.id
        }
    }

    private func previousParent(of id: UInt64) -> UInt64? {
        parentOf[id]
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

    // MARK: Events

    private func handleRaw(_ raw: [RawEvent]) {
        guard !logPaused else { return }
        for event in raw {
            let kind: EventRow.Kind = event.kind == .added ? .connected : .disconnected
            let title = "\(kind == .connected ? "Connected" : "Disconnected") — \(event.name.isEmpty ? event.className : event.name)"
            // Flood coalescing: a device flapping within 3 s becomes one ×N row.
            if var last = events.last, last.kind == kind, last.title == title,
               event.date.timeIntervalSince(last.date) < 3.0 {
                last.count += 1
                last.date = event.date
                events[events.count - 1] = last
                continue
            }
            appendEvent(EventRow(
                kind: kind,
                title: title,
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
