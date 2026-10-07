import SwiftUI
import AppKit
import PortreeCore

/// Four-tab inspector: Decoded (curated), Raw (every registry property +
/// hex viewer for blobs), Interfaces (USB interfaces or TB ports, with owning
/// driver), History (this session's events for the device).
struct InspectorView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: Tab = .decoded
    @State private var hexPayload: HexPayload?

    enum Tab: String, CaseIterable {
        case decoded = "Decoded"
        case raw = "Raw"
        case interfaces = "Interfaces"
        case history = "History"
        case bandwidth = "I/O"
    }

    var body: some View {
        if let node = store.selection.flatMap({ store.allNodes[$0] }) {
            VStack(alignment: .leading, spacing: 0) {
                header(node)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                ScrollView {
                    switch tab {
                    case .decoded: DecodedTab(node: node)
                    case .raw: RawTab(node: node, hexPayload: $hexPayload)
                    case .interfaces: InterfacesTab(node: node)
                    case .history: HistoryTab(node: node)
                    case .bandwidth: BandwidthTab(node: node)
                    }
                }
            }
            .sheet(item: $hexPayload) { payload in
                HexView(payload: payload)
            }
        } else {
            ContentUnavailableView(
                "No selection",
                systemImage: "cursorarrow.rays",
                description: Text("Select a device in the sidebar or graph.")
            )
        }
    }

    private func header(_ node: DeviceNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.category.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(node.tier.color)
                .frame(width: 30, height: 30)
                .background(node.tier.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.system(size: 13, weight: .semibold))
                Text(node.subtitle.isEmpty ? node.className : node.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
    }
}

// MARK: - Decoded

private struct DecodedTab: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let nodeIssues = store.issues.byNode[node.id], !nodeIssues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nodeIssues) { issue in
                        let color: Color = issue.severity == .problem ? .red
                            : (issue.severity == .warning ? .orange : .secondary)
                        let symbol = issue.severity == .problem ? "exclamationmark.octagon.fill"
                            : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Label(issue.title, systemImage: symbol)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(color)
                            Text(issue.detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            group("Identity") {
                row("Class", node.className)
                if let vid = node.vendorID, let pid = node.productID {
                    row("VID : PID", "\(Format.hex(vid, width: 4)) : \(Format.hex(pid, width: 4))")
                }
                if let cls = node.deviceClassCode {
                    row("USB class", Format.usbClassName(cls))
                }
                if let bcd = node.properties["bcdUSB"]?.intValue {
                    row("bcdUSB", Format.bcd(bcd))
                }
                if let serial = node.serialNumber {
                    row("Serial", serial)
                }
                if let uid = node.properties["UID"]?.intValue {
                    row("TB UID", Format.tbUID(uid))
                }
            }
            group("Link") {
                if !node.speedLabel.isEmpty { row("Speed", node.speedLabel) }
                if node.linkSpeedBps > 0 { row("UsbLinkSpeed", "\(node.linkSpeedBps) b/s") }
                if let speedEnum = node.properties["USBSpeed"]?.intValue {
                    row("USBSpeed enum", Format.usbSpeedEnumLabel(speedEnum))
                }
                if let portType = node.properties["USBPortType"]?.intValue {
                    row("Port type", Format.usbPortTypeLabel(portType))
                }
                if let location = node.locationID {
                    row("Location", "\(Format.locationPath(location))  (\(Format.hex(location, width: 8)))")
                }
                if let total = node.properties["Portree Ports Total"]?.intValue, total > 0 {
                    let free = node.properties["Portree Ports Free"]?.intValue ?? 0
                    let freeList = node.properties["Portree Free Ports"]?.stringValue.map { " · free: \($0)" } ?? ""
                    row("Ports", "\(total - free) used / \(total)\(freeList)")
                }
                if let route = node.properties["Route String"]?.intValue {
                    row("Route string", Format.hex(route))
                }
                if let rom = node.properties["ROM Version"]?.intValue,
                   let eeprom = node.properties["EEPROM Revision"]?.intValue, rom > 0 {
                    row("NVM version", Format.nvmVersion(rom: rom, eeprom: eeprom))
                }
                row("Tunneled", node.isTunneled ? "Yes (USB4/TB tunnel)" : (node.kind == .tbSwitch ? "native fabric" : "No"))
            }
            if let displayMode = store.displayModes[node.id] {
                group("Display") {
                    row("Mode", displayMode)
                }
            }
            group("Power & ownership") {
                if let power = node.powerSinkMA {
                    row("Power sink", "\(Format.milliamps(power))  /  3000 mA port limit")
                }
                if let owner = node.exclusiveOwner {
                    row("Exclusive owner", owner)
                }
                if node.powerSinkMA == nil && node.exclusiveOwner == nil {
                    row("—", "no power/ownership data")
                }
            }
            if let twin = node.twin {
                group("Merged hub twin") {
                    row("USB2 personality", twin.secondaryName)
                    row("Links", "\(Format.speedLabel(bps: twin.lowSpeedBps)) + \(Format.speedLabel(bps: twin.highSpeedBps))")
                    row("Why merged", "class 9, shared ContainerID, same controller, speed split")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: key.contains("VID") || key.contains("UID") || key.contains("Location") ? .monospaced : .default))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Raw

struct HexPayload: Identifiable {
    let id = UUID()
    let key: String
    let data: Data
}

private struct RawTab: View {
    let node: DeviceNode
    @Binding var hexPayload: HexPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(node.properties.keys.sorted(), id: \.self) { key in
                let value = node.properties[key]!
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                        .lineLimit(1)
                        .help(key)
                    if let data = value.dataValue {
                        Button {
                            hexPayload = HexPayload(key: key, data: data)
                        } label: {
                            Text(value.displayString + "  ⌗")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Open hex viewer")
                    } else {
                        Text(value.displayString)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1.5)
                .contextMenu {
                    Button("Copy value") { copy(value.displayString) }
                    Button("Copy key = value") { copy("\(key) = \(value.displayString)") }
                }
            }
            HStack {
                Spacer()
                Button("Copy all properties") {
                    let text = node.properties.keys.sorted()
                        .map { "\($0) = \(node.properties[$0]!.displayString)" }
                        .joined(separator: "\n")
                    copy(text)
                }
                .font(.system(size: 10.5))
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Interfaces

private struct InterfacesTab: View {
    let node: DeviceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.interfaces.isEmpty {
                Text(node.kind == .tbSwitch || node.kind == .tbDomain
                     ? "No adapter ports published."
                     : "No interfaces published for this node.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            ForEach(node.interfaces) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 11.5, weight: .semibold))
                    Text(entry.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }
}

// MARK: - Bandwidth (record mode)

private struct BandwidthTab: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let share = store.allocatedShare(of: node) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ALLOCATED (registry truth)")
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
                    Text("Negotiated \(node.speedLabel) — \(Int(share * 100))% of the upstream link")
                        .font(.system(size: 11.5))
                    ProgressView(value: share)
                        .tint(node.tier.color)
                }
            }

            if let samples = store.series[node.id], samples.contains(where: { $0 > 0 }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE THROUGHPUT (recorded)")
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
                    let current = store.rates[node.id] ?? 0
                    let peak = samples.max() ?? 0
                    HStack(spacing: 12) {
                        stat("Now", Theme.rate(current), .green)
                        stat("Peak", Theme.rate(peak), .orange)
                        if node.linkSpeedBps > 0 {
                            stat("Link", Format.speedLabel(bps: node.linkSpeedBps), node.tier.color)
                        }
                    }
                    Sparkline(samples: Array(samples.suffix(300)), color: node.tier.color)
                        .frame(height: 70)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    if node.linkSpeedBps > 0, peak > 0 {
                        Text("Peak used \(String(format: "%.1f", min(100, peak * 8 / Double(node.linkSpeedBps) * 100)))% of the negotiated link.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: store.isRecording ? "waveform.badge.magnifyingglass" : "record.circle")
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text(store.isRecording
                         ? "Recording — no byte counters for this device.\nOnly storage and network devices expose real counters; nothing is estimated."
                         : "Start record mode (toolbar ⏺) to sample real byte counters at 1 Hz.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color)
        }
    }
}

// MARK: - History

private struct HistoryTab: View {
    @Environment(AppStore.self) private var store
    let node: DeviceNode

    var body: some View {
        let related = store.events.filter { $0.nodeID == node.id || $0.title.contains(node.name) }
        VStack(alignment: .leading, spacing: 8) {
            if related.isEmpty {
                Text("No events for this device in the current session.\nReplug history persists from now on in the event log.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            ForEach(related.reversed()) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Theme.timestamp(row.date))  \(row.title)\(row.count > 1 ? "  ×\(row.count)" : "")")
                        .font(.system(size: 11, weight: .medium))
                    Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if node.serialNumber == nil && node.kind == .usbDevice {
                Text("No serial number — identity is keyed by VID+PID+location (low confidence).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
    }
}
