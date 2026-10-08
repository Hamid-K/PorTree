import SwiftUI
import PortreeCore

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var diagnosticsShown = false
    @State private var diffShown = false

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
                if store.isRecording {
                    Divider()
                    TrafficStripView()
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
                Picker("Layout", selection: $store.orientation) {
                    ForEach(LayoutOrientation.allCases, id: \.self) { orientation in
                        Image(systemName: orientation.symbol)
                            .help(orientation.label)
                            .tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .help("Graph direction")

                Button {
                    store.toggleRecording()
                } label: {
                    Image(systemName: store.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(store.isRecording ? Color.red : Color.primary)
                        .symbolEffect(.pulse, isActive: store.isRecording)
                }
                .help(store.isRecording ? "Stop recording throughput" : "Record live throughput (real counters only)")

                Toggle(isOn: $store.bandwidthOverlay) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                }
                .help("Bandwidth overlay (allocated share)")

                Button {
                    diagnosticsShown.toggle()
                } label: {
                    Image(systemName: "stethoscope")
                        .overlay(alignment: .topTrailing) {
                            let count = store.issues.all.count
                            if count > 0 {
                                let worst = store.issues.all.map(\.severity).max() ?? .info
                                Text("\(count)")
                                    .appFont(8, weight: .bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 0.5)
                                    .background(
                                        worst == .problem ? Color.red : (worst == .warning ? Color.orange : Color.gray),
                                        in: Capsule()
                                    )
                                    .offset(x: 8, y: -7)
                            }
                        }
                }
                .help("Diagnostics — auto-run on every change")
                .popover(isPresented: $diagnosticsShown, arrowEdge: .bottom) { DiagnosticsView() }

                Button {
                    diffShown.toggle()
                } label: {
                    Image(systemName: "plus.slash.minus")
                        .overlay(alignment: .topTrailing) {
                            if let diff = store.baselineDiff, diff.totalCount > 0 {
                                Text("\(diff.totalCount)")
                                    .appFont(8, weight: .bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 0.5)
                                    .background(Color.green, in: Capsule())
                                    .offset(x: 8, y: -7)
                            }
                        }
                }
                .help("Baseline diff — freeze or load a state, compare against live")
                .popover(isPresented: $diffShown, arrowEdge: .bottom) { DiffPanelView() }

                Button {
                    store.toolboxShown = true
                } label: { Image(systemName: "wrench.and.screwdriver") }
                    .help("Debugging toolbox (⌘T)")

                Button {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app"),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                } label: { Image(systemName: "list.clipboard") }
                    .help("Open macOS System Information")

                Toggle(isOn: $store.legendShown) {
                    Image(systemName: "paintpalette")
                }
                .help("Legend overlay")

                Toggle(isOn: $store.redactExports) {
                    Image(systemName: store.redactExports ? "eye.slash.fill" : "eye.slash")
                        .foregroundStyle(store.redactExports ? .orange : .secondary)
                }
                .help("Privacy: mask identifiers (serials, UIDs, EDID) in exports — the live view is never masked")

                Menu {
                    Picker("Appearance", selection: $store.appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    Picker("Canvas", selection: $store.canvasBackground) {
                        ForEach(CanvasBackground.allCases, id: \.self) { background in
                            Text(background.label).tag(background)
                        }
                    }
                    Divider()
                    Button("Expand All Tags") { store.expandAllTags() }
                    Button("Collapse All Tags") { store.collapseAllTags() }
                    Divider()
                    Toggle("Power sparkline in cards (recording)", isOn: $store.powerOverlay)
                    Divider()
                    Toggle("Connection sounds", isOn: $store.soundsEnabled)
                    Toggle("Device guard (flag unknown devices)", isOn: $store.deviceGuard)
                    Button("Trust All Connected Devices") { store.trustAllConnected() }
                    Divider()
                    Toggle("Check for updates at launch", isOn: Bindable(store.updates).autoCheckEnabled)
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .help("Canvas background · overlays · sounds · device guard")

                Toggle(isOn: $store.drawerShown) {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help("Event log")

                Button {
                    store.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan (⌘R)")

                if store.updates.hasNews || store.updates.panelShown {
                    Button {
                        store.updates.panelShown = true
                    } label: {
                        switch store.updates.state {
                        case .failed:
                            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                .foregroundStyle(.orange)
                        case .downloading, .installing:
                            Image(systemName: "arrow.down.circle.dotted")
                                .foregroundStyle(.secondary)
                        default:
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                                .symbolEffect(.pulse)
                        }
                    }
                    .help({
                        switch store.updates.state {
                        case .failed: "Update check failed"
                        case .downloading, .installing: "Updating…"
                        default: "Update available"
                        }
                    }())
                    .popover(isPresented: Bindable(store.updates).panelShown, arrowEdge: .bottom) {
                        UpdatePanel(updates: store.updates)
                    }
                }
            }
        }
        .sheet(isPresented: $store.toolboxShown) { ToolboxView() }
        .environment(\.fontScale, store.fontScale)
        .preferredColorScheme(store.appearance.colorScheme)
        .task { store.start() }
    }

    private var subtitle: String {
        guard let snapshot = store.snapshot else { return "reading IORegistry…" }
        if let result = store.searchResult {
            let count = result.matches.count
            return "\(count) match\(count == 1 ? "" : "es") for “\(store.searchText)” · ⌘G cycles"
        }
        let tbCount = snapshot.tbRoots.count
        return "\(snapshot.deviceCount) devices · \(tbCount) TB/USB4 domain\(tbCount == 1 ? "" : "s")"
            + (store.lastRefresh.map { " · refreshed \(Theme.timestamp($0))" } ?? "")
    }
}

/// Live traffic strip (record mode): aggregate throughput bar graph with the
/// current total, elapsed time, and the busiest devices as clickable chips.
private struct TrafficStripView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Text("REC")
                    .appFont(11, weight: .heavy)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Theme.rate(store.totalSeries.last ?? 0))
                        .appFont(13, weight: .bold, design: .monospaced)
                    Text(elapsed)
                        .appFont(9)
                        .foregroundStyle(.secondary)
                    Text("TOTAL · all monitored devices")
                        .appFont(8, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 168, alignment: .leading)

            Sparkline(samples: store.totalSeries, color: .green, capacity: 150, lineWidth: 1.6, tick: store.sampleCount)
                .frame(maxWidth: .infinity, maxHeight: 34)

            VStack(alignment: .trailing, spacing: 1) {
                let talkers = store.topTalkers
                if talkers.isEmpty {
                    Text("waiting for traffic…")
                        .appFont(9.5)
                        .foregroundStyle(.tertiary)
                }
                ForEach(talkers, id: \.id) { talker in
                    Button {
                        store.jump(to: talker.id)
                    } label: {
                        Text("\(talker.name)  \(Theme.rate(talker.rate))")
                            .appFont(9.5, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 230, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var elapsed: String {
        guard let start = store.recordingStart else { return "" }
        let seconds = Int(Date().timeIntervalSince(start))
        return String(format: "REC %d:%02d · %d samples", seconds / 60, seconds % 60, store.sampleCount)
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
            .appFont(11, design: .monospaced)
        } actions: {
            Button("Rescan") { store.refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LegendView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.legendCollapsed {
            // Folded: a small chip that expands on click.
            Button {
                withAnimation(.snappy) { store.legendCollapsed = false }
            } label: {
                Label("Legend", systemImage: "paintpalette")
                    .appFont(10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Expand the legend")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Links").appFont(10, weight: .bold).foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    Image(systemName: "chevron.down")
                        .appFont(8.5, weight: .bold)
                        .foregroundStyle(.tertiary)
                }
                ForEach([Tier.usb1, .usb2, .usb3, .usb4, .thunderbolt, .fabric, .infrastructure, .error], id: \.self) { tier in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tier.color)
                            .frame(width: 20, height: max(2, tier == .usb1 ? 2 : Theme.edgeWidth(bps: representativeBps(tier))))
                        Text(tier.legendLabel).appFont(10)
                    }
                }
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.pink)
                        .frame(width: 20, height: 2)
                    Text("video on link (DP tunnel / DisplayLink)").appFont(10)
                }
                Divider().frame(width: 180)
                Text("thickness = speed · dashed = USB 1.x\nwide soft bar = system backbone")
                    .appFont(9)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture {
                withAnimation(.snappy) { store.legendCollapsed = true }
            }
            .help("Click to fold the legend")
        }
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
