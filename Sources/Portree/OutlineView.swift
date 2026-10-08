import SwiftUI
import PortreeCore

/// Sidebar outline. Uses OutlineGroup-style recursion with explicit
/// DisclosureGroup bindings into the store's shared collapsed set —
/// List(children:) owns its disclosure state privately and cannot stay in
/// sync with the graph.
struct OutlineView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Sidebar mode", selection: $store.sidebarMode) {
                ForEach(AppStore.SidebarMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if store.sidebarMode == .topology {
                topologyList
            } else {
                typesList
            }
        }
    }

    private var topologyList: some View {
        let search = store.searchResult
        // Sidebar selection also centers the graph on the picked device
        // (card clicks don't — the card is already in view).
        let selection = Binding<UInt64?>(
            get: { store.selection },
            set: { newValue in
                store.selection = newValue
                if let newValue { store.pendingScrollTarget = newValue }
            }
        )

        return List(selection: selection) {
            if let system = store.systemDisplayNode {
                Section("System") {
                    OutlineNodeRow(node: { var s = system; s.children = []; return s }(), search: search)
                }
            }
            if !store.displayEntries.isEmpty {
                Section("Displays") {
                    ForEach(store.displayEntries) { entry in
                        DisplayEntryRow(entry: entry)
                    }
                }
            }
            Section("USB") {
                ForEach(filteredRoots(store.usbDisplayRoots, search: search)) { root in
                    OutlineNodeRow(node: root, search: search)
                }
            }
            Section("Thunderbolt / USB4") {
                ForEach(filteredRoots(store.tbDisplayRoots, search: search)) { root in
                    OutlineNodeRow(node: root, search: search)
                }
            }
            if !store.pciDisplayRoots.isEmpty {
                Section("PCIe") {
                    ForEach(filteredRoots(store.pciDisplayRoots, search: search)) { root in
                        OutlineNodeRow(node: root, search: search)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UInt64.self) { ids in
            if let id = ids.first, let node = store.allNodes[id] {
                if store.untrustedIDs.contains(id) {
                    Button("Trust this device") { store.trustDevice(node) }
                    Divider()
                }
                Button("Copy device name") { copyToPasteboard(node.name) }
                if let idPair = node.idPairLabel {
                    Button("Copy device ID") { copyToPasteboard(idPair) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.selection = id }
        }
        .overlay {
            if store.snapshot == nil {
                ProgressView("Reading IORegistry…")
            } else if let search, search.matches.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }

    private func filteredRoots(_ roots: [DeviceNode], search: (matches: Set<UInt64>, visible: Set<UInt64>)?) -> [DeviceNode] {
        guard let search else { return roots }
        return roots.filter { search.visible.contains($0.id) }
    }

    /// Flat device-type filter: one section per category present, rows
    /// spotlight their device in the graph (same fade-out as search).
    private var typesList: some View {
        let byCategory = Dictionary(grouping: store.allNodes.values.filter { node in
            node.kind != .system && !store.ghostIDs.contains(node.id)
        }) { store.effectiveCategory(of: $0) }

        return List {
            if !store.displayEntries.isEmpty {
                Section("Displays") {
                    ForEach(store.displayEntries) { entry in
                        DisplayEntryRow(entry: entry)
                    }
                }
            }
            if !store.cableEntries.isEmpty {
                Section("Cables & Ports") {
                    ForEach(store.cableEntries) { entry in
                        CableEntryRow(entry: entry)
                    }
                }
            }
            if !store.powerRows.isEmpty {
                Section("Power") {
                    ForEach(store.powerRows) { row in
                        PowerEntryRow(row: row)
                    }
                }
            }
            ForEach(DeviceCategory.typeOrder.filter { $0 != .display }, id: \.self) { category in
                if let nodes = byCategory[category], !nodes.isEmpty {
                    Section(category.typeLabel) {
                        ForEach(nodes.sorted { $0.name < $1.name }) { node in
                            TypeRow(node: node)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One screen in the Displays section; selecting it spotlights the node that
/// is (or drives) the display.
private struct DisplayEntryRow: View {
    @Environment(AppStore.self) private var store
    let entry: AppStore.DisplayEntry

    var body: some View {
        Button {
            if let nodeID = entry.nodeID { store.focusNode(nodeID) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.isBuiltIn ? "laptopcomputer" : "display")
                    .appFont(10.5)
                    .foregroundStyle(.pink)
                    .frame(width: 18, height: 18)
                    .background(Color.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).appFont(12).lineLimit(1)
                    Text(entry.detail).appFont(9.5).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                if entry.nodeID == nil {
                    Image(systemName: "questionmark.circle")
                        .appFont(9.5)
                        .foregroundStyle(.secondary)
                        .help("Not attributable to a single graph node")
                }
            }
        }
        .buttonStyle(.plain)
        .help(entry.nodeID != nil ? "Click to spotlight in the graph" : entry.detail)
    }
}

/// One physical receptacle: the cable's eMarker facts (or "empty"), with the
/// graph spotlight landing on the first-hop device the cable feeds.
private struct CableEntryRow: View {
    @Environment(AppStore.self) private var store
    let entry: AppStore.CableEntry

    var body: some View {
        Button {
            if let nodeID = entry.nodeID { store.focusNode(nodeID) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.powered ? "powercord.fill" : "cable.connector")
                    .appFont(10.5)
                    .foregroundStyle(entry.active ? (entry.powered ? .orange : .indigo) : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        (entry.active ? (entry.powered ? Color.orange : Color.indigo) : Color.secondary).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.portLabel).appFont(12).lineLimit(1)
                    Text(entry.detail)
                        .appFont(9.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
            }
            .opacity(entry.active ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(entry.nodeID != nil ? "Click to spotlight the first-hop device" : entry.detail)
    }
}

/// One fact about the Mac's power input (source, live draw, PDO menu).
private struct PowerEntryRow: View {
    @Environment(AppStore.self) private var store
    let row: AppStore.PowerRow

    var body: some View {
        Button {
            if let nodeID = row.nodeID { store.focusNode(nodeID) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.icon)
                    .appFont(10.5)
                    .foregroundStyle(row.negotiated || row.id == "source" ? .orange : .secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.orange.opacity(row.negotiated || row.id == "source" ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).appFont(12).lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .appFont(9.5)
                            .foregroundStyle(row.negotiated ? Color.orange : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if row.negotiated {
                    Image(systemName: "checkmark.circle.fill").appFont(10).foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// One device in the by-type filter; selecting spotlights it in the graph.
private struct TypeRow: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode

    var body: some View {
        Button {
            store.focusNode(node.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.effectiveCategory(of: node).symbol)
                    .appFont(10.5)
                    .foregroundStyle(node.tier.color)
                    .frame(width: 18, height: 18)
                    .background(node.tier.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                Text(node.name)
                    .appFont(12)
                    .lineLimit(1)
                if store.untrustedIDs.contains(node.id) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .appFont(10)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
                Spacer(minLength: 2)
                if !node.speedLabel.isEmpty {
                    Text(node.speedLabel)
                        .appFont(9.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .background(
                store.selection == node.id ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if store.untrustedIDs.contains(node.id) {
                Button("Trust this device") { store.trustDevice(node) }
                Divider()
            }
            Button("Copy device name") { copyToPasteboard(node.name) }
            if let idPair = node.idPairLabel {
                Button("Copy device ID") { copyToPasteboard(idPair) }
            }
        }
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct OutlineNodeRow: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode
    let search: (matches: Set<UInt64>, visible: Set<UInt64>)?

    var body: some View {
        let visibleChildren = node.children.filter { search?.visible.contains($0.id) ?? true }

        if visibleChildren.isEmpty {
            label
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { !store.collapsed.contains(node.id) },
                    set: { expanded in
                        if expanded { store.collapsed.remove(node.id) } else { store.collapsed.insert(node.id) }
                    }
                )
            ) {
                ForEach(visibleChildren) { child in
                    OutlineNodeRow(node: child, search: search)
                }
            } label: {
                label
            }
        }
    }

    /// Same transient cues as the graph: green flash on arrival, yellow on
    /// re-enumeration, red strike/ghost on removal, persistent red + shield
    /// while the device guard distrusts it.
    private var rowTint: Color? {
        if store.untrustedIDs.contains(node.id) { return .red }
        if store.ghostIDs.contains(node.id) { return nil }
        if store.arrivalIDs.contains(node.id) { return .green }
        if store.reenumeratedIDs.contains(node.id) { return .yellow }
        return nil
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: store.effectiveCategory(of: node).symbol)
                .appFont(10.5)
                .foregroundStyle(node.tier.color)
                .frame(width: 18, height: 18)
                .background(node.tier.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            Text(node.name)
                .appFont(12)
                .strikethrough(store.ghostIDs.contains(node.id))
                .lineLimit(1)
            if store.untrustedIDs.contains(node.id) {
                Image(systemName: "exclamationmark.shield.fill")
                    .appFont(10)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .help("Never seen on this Mac — right-click to trust")
            }
            Spacer(minLength: 2)
            if !node.speedLabel.isEmpty {
                Text(node.speedLabel)
                    .appFont(9.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 3)
        .background(
            (rowTint ?? .clear).opacity(rowTint == nil ? 0 : 0.16),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .animation(.easeOut(duration: 0.4), value: rowTint)
        .opacity(store.ghostIDs.contains(node.id) ? 0.5 : 1)
        .tag(node.id)
    }
}
