import SwiftUI
import PortreeCore

struct ContentView: View {
    @Environment(AppStore.self) private var store

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
                    store.toolboxShown = true
                } label: { Image(systemName: "wrench.and.screwdriver") }
                    .help("Debugging toolbox (⌘T)")

                Toggle(isOn: $store.legendShown) {
                    Image(systemName: "paintpalette")
                }
                .help("Legend overlay")

                Menu {
                    Picker("Canvas", selection: $store.canvasBackground) {
                        ForEach(CanvasBackground.allCases, id: \.self) { background in
                            Text(background.label).tag(background)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .help("Canvas background")

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
        .sheet(isPresented: $store.toolboxShown) { ToolboxView() }
        .task { store.start() }
    }

    private var subtitle: String {
        guard let snapshot = store.snapshot else { return "reading IORegistry…" }
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
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Theme.rate(store.totalSeries.last ?? 0))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(elapsed)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 118, alignment: .leading)

            TrafficBars(samples: Array(store.totalSeries.suffix(150)))
                .frame(maxWidth: .infinity, maxHeight: 34)

            VStack(alignment: .trailing, spacing: 1) {
                let talkers = store.topTalkers
                if talkers.isEmpty {
                    Text("waiting for traffic…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(talkers, id: \.id) { talker in
                    Button {
                        store.jump(to: talker.id)
                    } label: {
                        Text("\(talker.name)  \(Theme.rate(talker.rate))")
                            .font(.system(size: 9.5, design: .monospaced))
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

private struct TrafficBars: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let peak = max(samples.max() ?? 1, 1)
            let barWidth = max(2, size.width / CGFloat(max(samples.count, 60)) - 1)
            for (index, value) in samples.enumerated() {
                let height = max(1.5, size.height * CGFloat(value / peak))
                let x = size.width - CGFloat(samples.count - index) * (barWidth + 1)
                guard x > -barWidth else { continue }
                let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(value > 0 ? .green.opacity(0.75) : .gray.opacity(0.25))
                )
            }
        }
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

struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Links").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            ForEach([Tier.usb1, .usb2, .usb3, .usb4, .thunderbolt, .infrastructure, .error], id: \.self) { tier in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tier.color)
                        .frame(width: 20, height: max(2, tier == .usb1 ? 2 : Theme.edgeWidth(bps: representativeBps(tier))))
                    Text(tier.legendLabel).font(.system(size: 10))
                }
            }
            Divider().frame(width: 180)
            Text("thickness = speed · dashed = USB 1.x\nwide soft bar = system backbone")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
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
