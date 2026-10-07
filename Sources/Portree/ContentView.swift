import SwiftUI
import PortreeCore

/// Placeholder shell for the first toolchain proof (M1): a one-shot snapshot
/// rendered as a flat device list. Replaced by the full three-pane UI in M2+.
struct ContentView: View {
    @State private var devices: [DeviceNode] = []

    var body: some View {
        List(devices) { node in
            HStack {
                Text(node.name)
                Spacer()
                Text(node.speedLabel.isEmpty ? node.subtitle : node.speedLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let snapshot = Snapshot(usbRoots: USBTopologyBuilder.build(), tbRoots: TBTopologyBuilder.build())
            devices = snapshot.allRoots.flatMap { $0.flattened() }
        }
    }
}
