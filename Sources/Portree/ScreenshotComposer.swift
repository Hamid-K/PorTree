import SwiftUI
import AppKit
import PortreeCore

/// Headless press-shot: composes the app's real panes (sidebar outline, graph
/// canvas, inspector) around a live snapshot and renders them to a PNG at 2×.
/// Used by `portree --export-screenshot <path>` so the repository screenshot
/// is reproducible on any machine. NavigationSplitView and toolbars need a
/// window, so the shell chrome is a faithful recreation; the graph and
/// inspector content are the real views.
@MainActor
enum ScreenshotComposer {

    static func export(to url: URL) -> Bool {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let store = AppStore.shared
        store.canvasBackground = .graphite
        store.prepareHeadlessScreenshot()

        let size = CGSize(width: 1760, height: 1040)
        let content = ComposedShot(store: store, size: size)
            .environment(store)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}

private struct ComposedShot: View {
    let store: AppStore
    let size: CGSize

    private let sidebarWidth: CGFloat = 268
    private let inspectorWidth: CGFloat = 332
    private let titleBarHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Color.black.opacity(0.4))
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                Divider().overlay(Color.black.opacity(0.4))
                graphPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Color.black.opacity(0.4))
                inspectorPane
                    .frame(width: inspectorWidth, alignment: .top)
                    .background(Color(red: 0.13, green: 0.13, blue: 0.15))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
        .preferredColorScheme(.dark)
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
            }
            Text("Portree").font(.system(size: 13, weight: .semibold))
            if let snapshot = store.snapshot {
                Text("\(snapshot.deviceCount) devices · \(snapshot.tbRoots.count) TB/USB4 domains · \(snapshot.pciRoots.count) PCIe roots")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                Image(systemName: "gauge.with.dots.needle.33percent")
                Image(systemName: "stethoscope")
                Image(systemName: "wrench.and.screwdriver")
                Image(systemName: "paintpalette")
                Image(systemName: "arrow.clockwise")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: titleBarHeight)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17))
    }

    // Simplified (non-List) rendition of the sidebar outline — List does not
    // render reliably under ImageRenderer.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("System")
            if let system = store.systemDisplayNode { sidebarRow(system, depth: 0, recurse: false) }
            sectionHeader("USB")
            ForEach(store.usbDisplayRoots) { root in sidebarRows(root, depth: 0) }
            sectionHeader("Thunderbolt / USB4")
            ForEach(store.tbDisplayRoots) { root in sidebarRows(root, depth: 0) }
            sectionHeader("PCIe")
            ForEach(store.pciDisplayRoots.suffix(3)) { root in sidebarRows(root, depth: 0) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color(red: 0.14, green: 0.14, blue: 0.16))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func sidebarRows(_ node: DeviceNode, depth: Int) -> some View {
        sidebarRow(node, depth: depth, recurse: true)
    }

    @ViewBuilder
    private func sidebarRow(_ node: DeviceNode, depth: Int, recurse: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.category.symbol)
                .font(.system(size: 10))
                .foregroundStyle(node.tier.color)
                .frame(width: 17, height: 17)
                .background(node.tier.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            Text(node.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 2)
            if !node.speedLabel.isEmpty {
                Text(node.speedLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.07), in: Capsule())
            }
        }
        .padding(.vertical, 2.5)
        .padding(.leading, 6 + CGFloat(depth) * 13)
        .padding(.trailing, 6)
        .background(
            store.selection == node.id ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        if recurse {
            ForEach(node.children) { child in
                AnyView(sidebarRow(child, depth: depth + 1, recurse: true))
            }
        }
    }

    // Composer-native inspector (Picker/ScrollView don't survive ImageRenderer).
    @ViewBuilder
    private var inspectorPane: some View {
        if let node = store.selection.flatMap({ store.allNodes[$0] }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: node.category.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(node.tier.color)
                        .frame(width: 30, height: 30)
                        .background(node.tier.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).font(.system(size: 13, weight: .semibold))
                        Text(node.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(["Decoded", "Raw", "Interfaces", "History", "I/O"], id: \.self) { tab in
                        Text(tab)
                            .font(.system(size: 10.5, weight: tab == "Decoded" ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(
                                tab == "Decoded" ? Color.white.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .foregroundStyle(tab == "Decoded" ? .primary : .secondary)
                    }
                }
                inspectorGroup("Identity") {
                    if let vid = node.vendorID, let pid = node.productID {
                        inspectorRow("VID : PID", "\(Format.hex(vid, width: 4)) : \(Format.hex(pid, width: 4))")
                    }
                    if let cls = node.deviceClassCode { inspectorRow("USB class", Format.usbClassName(cls)) }
                    if let serial = node.serialNumber { inspectorRow("Serial", String(serial.prefix(26))) }
                    inspectorRow("Driver class", node.className)
                }
                inspectorGroup("Link") {
                    if !node.speedLabel.isEmpty { inspectorRow("Speed", node.speedLabel) }
                    if node.linkSpeedBps > 0 { inspectorRow("UsbLinkSpeed", "\(node.linkSpeedBps) b/s") }
                    if let location = node.locationID { inspectorRow("Location", Format.locationPath(location)) }
                    inspectorRow("Tunneled", node.isTunneled ? "Yes (USB4/TB tunnel)" : "No")
                }
                if let power = node.powerSinkMA {
                    inspectorGroup("Power") {
                        inspectorRow("Sink allocation", "\(power) mA / 3000 mA port limit")
                    }
                }
                if let twin = node.twin {
                    inspectorGroup("Merged hub twin") {
                        inspectorRow("USB2 personality", twin.secondaryName)
                        inspectorRow("Links", "\(Format.speedLabel(bps: twin.lowSpeedBps)) + \(Format.speedLabel(bps: twin.highSpeedBps))")
                    }
                }
                if let issues = store.issues.byNode[node.id], !issues.isEmpty {
                    inspectorGroup("Doctor") {
                        ForEach(issues) { issue in
                            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func inspectorGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            content()
        }
    }

    private func inspectorRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var graphPane: some View {
        let layout = TreeLayout(
            systemRoot: store.systemDisplayNode,
            usbRoots: store.usbDisplayRoots,
            tbRoots: store.tbDisplayRoots,
            pciRoots: store.pciDisplayRoots,
            collapsed: [],
            orientation: .leftToRight
        )
        let paneSize = CGSize(
            width: size.width - sidebarWidth - inspectorWidth - 2,
            height: size.height - titleBarHeight - 1
        )
        let scale = min(1.0, (paneSize.width - 40) / layout.size.width, (paneSize.height - 40) / layout.size.height)

        return ZStack(alignment: .topLeading) {
            store.canvasBackground.color
            GraphCanvas(store: store, layout: layout)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: layout.size.width * scale,
                    height: layout.size.height * scale,
                    alignment: .topLeading
                )
                .padding(10)
            VStack { Spacer(); HStack { Spacer(); LegendView().padding(10) } }
        }
        .frame(width: paneSize.width, height: paneSize.height)
        .clipped()
    }
}
