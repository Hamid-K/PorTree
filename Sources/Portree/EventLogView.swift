import SwiftUI
import PortreeCore

/// Bottom drawer: timestamped connect/disconnect/re-enumeration stream,
/// flood-coalesced (×N), newest at the top, click-to-reveal the node.
struct EventLogView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Event Log").appFont(11, weight: .semibold)
                Text("\(store.events.count) rows")
                    .appFont(10)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $store.logPaused) {
                    Image(systemName: store.logPaused ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(store.logPaused ? "Resume logging" : "Pause logging")
                Button("Clear") { store.clearEvents() }
                    .controlSize(.small)
                Text(store.eventLogPath)
                    .appFont(9, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.events.reversed()) { row in
                        EventRowView(row: row)
                    }
                    if store.events.isEmpty {
                        Text("No events yet — plug or unplug something.")
                            .appFont(11)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .frame(height: 150)
        .background(.bar)
    }
}

private struct EventRowView: View {
    @Environment(AppStore.self) private var store
    let row: EventRow

    private var color: Color {
        switch row.kind {
        case .connected: return .green
        case .disconnected: return .red
        case .reenumerated: return .yellow
        case .rescan, .info: return .gray
        case .export: return .blue
        case .alert: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(Theme.timestamp(row.date))
                .appFont(10, design: .monospaced)
                .foregroundStyle(.tertiary)
            Text(row.title + (row.count > 1 ? "  ×\(row.count)" : ""))
                .appFont(11, weight: .medium)
                .lineLimit(1)
            Text(row.detail)
                .appFont(10.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = row.nodeID, store.allNodes[id] != nil { store.jump(to: id) }
        }
        .background(
            row.nodeID.map { store.selection == $0 } == true ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }
}
