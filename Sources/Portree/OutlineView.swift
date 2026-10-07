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
        let search = store.searchResult

        List(selection: $store.selection) {
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
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UInt64.self) { _ in } primaryAction: { ids in
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

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: node.category.symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(node.tier.color)
                .frame(width: 18, height: 18)
                .background(node.tier.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            Text(node.name)
                .font(.system(size: 12))
                .strikethrough(store.ghostIDs.contains(node.id))
                .lineLimit(1)
            Spacer(minLength: 2)
            if !node.speedLabel.isEmpty {
                Text(node.speedLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .opacity(store.ghostIDs.contains(node.id) ? 0.5 : 1)
        .tag(node.id)
    }
}
