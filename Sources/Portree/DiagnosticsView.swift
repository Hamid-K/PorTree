import SwiftUI
import PortreeCore

/// The Doctor's waiting room: every finding across the whole topology in one
/// list, re-computed automatically on each snapshot. Click a row to jump to
/// and flash the affected device.
struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store

    private var sorted: [Doctor.Issue] {
        store.issues.all.sorted {
            $0.severity == $1.severity ? $0.title < $1.title : $0.severity > $1.severity
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Diagnostics", systemImage: "stethoscope")
                    .appFont(13, weight: .semibold)
                Spacer()
                Text("auto-run on every change")
                    .appFont(9.5)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            Divider()

            if sorted.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .appFont(26)
                        .foregroundStyle(.green)
                    Text("No issues detected")
                        .appFont(12, weight: .semibold)
                    Text(summary)
                        .appFont(10.5)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sorted) { issue in
                            IssueRow(issue: issue)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }

    private var summary: String {
        guard let snapshot = store.snapshot else { return "" }
        return "Checked \(snapshot.deviceCount) devices across \(snapshot.usbRoots.count) USB controllers, "
            + "\(snapshot.tbRoots.count) TB/USB4 domains and \(snapshot.pciRoots.count) PCIe roots.\n"
            + "Rules: throttling · bottlenecked hubs · rated speed · power budget & near-limit · overcurrent · port errors · hub depth · TT contention · TB down-training"
    }
}

private struct IssueRow: View {
    @Environment(AppStore.self) private var store
    let issue: Doctor.Issue

    var body: some View {
        Button {
            store.jump(to: issue.nodeID)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .appFont(13)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(issue.title).appFont(11.5, weight: .semibold)
                        if let node = store.allNodes[issue.nodeID] {
                            Text(node.name)
                                .appFont(10.5)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(issue.detail)
                        .appFont(10)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.forward.circle")
                    .foregroundStyle(.tertiary)
                    .appFont(11)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch issue.severity {
        case .problem: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private var symbol: String {
        switch issue.severity {
        case .problem: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}
