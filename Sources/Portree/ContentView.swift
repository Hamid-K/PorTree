import SwiftUI
import PortreeCore

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var legendShown = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            OutlineView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if store.snapshot != nil && store.allNodes.values.contains(where: { $0.kind == .usbDevice || $0.kind == .tbSwitch }) == false {
                    EmptyStateView()
                } else {
                    GraphView()
                }
                if store.drawerShown {
                    Divider()
                    EventLogView()
                }
            }
        }
        .inspector(isPresented: $store.inspectorShown) {
            InspectorView()
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Name, VID:PID, serial…")
        .navigationTitle("Portree")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.zoom = max(0.25, store.zoom / 1.2)
                } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)")
                Button {
                    store.zoom = 1.0
                } label: { Image(systemName: "1.magnifyingglass") }
                    .help("Actual size (⌘0)")
                Button {
                    store.zoom = min(2.0, store.zoom * 1.2)
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)")

                Button {
                    legendShown.toggle()
                } label: { Image(systemName: "paintpalette") }
                    .help("Legend")
                    .popover(isPresented: $legendShown, arrowEdge: .bottom) { LegendView() }

                Toggle(isOn: $store.drawerShown) {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help("Event log")

                Button {
                    store.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan (⌘R)")
            }
        }
        .task { store.start() }
    }

    private var subtitle: String {
        guard let snapshot = store.snapshot else { return "reading IORegistry…" }
        let tbCount = snapshot.tbRoots.count
        return "\(snapshot.deviceCount) devices · \(tbCount) TB/USB4 domain\(tbCount == 1 ? "" : "s")"
            + (store.lastRefresh.map { " · refreshed \(Theme.timestamp($0))" } ?? "")
    }
}

/// Zero devices or a failed walk must say so loudly with self-diagnostics —
/// never render a silently blank canvas (SPUSBDataType already broke this way
/// on this machine; if the IOKit walk ever does the same, the user needs to
/// know in one glance).
private struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("No devices found", systemImage: "cable.connector.slash")
        } description: {
            Text("""
            The IORegistry walk returned no USB devices or Thunderbolt switches.
            Controllers found: \(store.snapshot?.usbRoots.count ?? 0) · TB domains: \(store.snapshot?.tbRoots.count ?? 0)
            Cross-check with:  ioreg -p IOUSB
            """)
            .font(.system(size: 11, design: .monospaced))
        } actions: {
            Button("Rescan") { store.refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend").font(.system(size: 12, weight: .semibold))
            ForEach([Tier.usb1, .usb2, .usb3, .usb4, .thunderbolt, .infrastructure, .error], id: \.self) { tier in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tier.color)
                        .frame(width: 22, height: tier == .usb1 ? 2 : Theme.edgeWidth(bps: representativeBps(tier)))
                    Text(tier.legendLabel).font(.system(size: 11))
                }
            }
            Divider()
            Text("Border & edge color = protocol tier · edge thickness = speed\nIcon = device class · speed is always shown as text too")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func representativeBps(_ tier: Tier) -> Int64 {
        switch tier {
        case .usb1: return 12_000_000
        case .usb2: return 480_000_000
        case .usb3: return 10_000_000_000
        case .usb4: return 40_000_000_000
        case .thunderbolt: return 80_000_000_000
        default: return 0
        }
    }
}
