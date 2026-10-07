import SwiftUI
import PortreeCore

/// Baseline comparison panel: what appeared, vanished, or changed since the
/// frozen (or loaded) state — the "why is there a new HID device" view.
struct DiffPanelView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Baseline Diff", systemImage: "plus.slash.minus")
                    .appFont(13, weight: .semibold)
                Spacer()
                if let diff = store.baselineDiff {
                    Text("vs \(diff.baselineDate.formatted(date: .abbreviated, time: .shortened))")
                        .appFont(9.5)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            Divider()

            if let diff = store.baselineDiff {
                if diff.totalCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "equal.circle.fill")
                            .appFont(26).foregroundStyle(.green)
                        Text("Identical to baseline").appFont(12, weight: .semibold)
                        Text("Every device identity matches — nothing added, removed, or changed.")
                            .appFont(10.5).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !diff.addedIDs.isEmpty {
                                section("Added — not in baseline", color: .green) {
                                    ForEach(Array(diff.addedIDs).sorted(), id: \.self) { id in
                                        if let node = store.allNodes[id] {
                                            row(symbol: "plus.circle.fill", color: .green,
                                                title: node.name,
                                                detail: node.subtitle + (node.speedLabel.isEmpty ? "" : " · \(node.speedLabel)"),
                                                jumpTo: id)
                                        }
                                    }
                                }
                            }
                            if !diff.removed.isEmpty {
                                section("Removed — in baseline, absent now", color: .red) {
                                    ForEach(diff.removed) { node in
                                        row(symbol: "minus.circle.fill", color: .red,
                                            title: node.name,
                                            detail: node.subtitle + (node.speedLabel.isEmpty ? "" : " · was \(node.speedLabel)"),
                                            jumpTo: nil)
                                    }
                                }
                            }
                            if !diff.changed.isEmpty {
                                section("Changed — same identity, different facts", color: .yellow) {
                                    ForEach(diff.changed) { change in
                                        row(symbol: "arrow.triangle.2.circlepath.circle.fill", color: .yellow,
                                            title: change.name,
                                            detail: change.changes.joined(separator: " · "),
                                            jumpTo: change.id)
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 380)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.metering.center.weighted")
                        .appFont(24).foregroundStyle(.tertiary)
                    Text("No baseline set").appFont(12, weight: .semibold)
                    Text("Capture the current state (or load a saved snapshot JSON),\nthen replug, reboot, or wait — and diff against it.")
                        .appFont(10.5).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }

            Divider()
            HStack(spacing: 8) {
                Button("Capture Now") { store.captureBaseline() }
                Button("Load…") { store.loadBaseline() }
                Button("Save…") { store.saveBaseline() }
                    .disabled(store.snapshot == nil)
                Spacer()
                Button("Clear") { store.clearBaseline() }
                    .disabled(store.baseline == nil)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 400)
    }

    private func section(_ title: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .appFont(9.5, weight: .bold)
                .foregroundStyle(color)
            content()
        }
    }

    private func row(symbol: String, color: Color, title: String, detail: String, jumpTo id: UInt64?) -> some View {
        Button {
            if let id { store.jump(to: id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color).appFont(12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).appFont(11.5, weight: .semibold)
                    Text(detail).appFont(10).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if id != nil {
                    Image(systemName: "arrow.forward.circle").foregroundStyle(.tertiary).appFont(11)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(id == nil)
    }
}
