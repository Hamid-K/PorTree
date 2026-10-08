import SwiftUI
import PortreeCore

/// The update popover: version, full CHANGELOG (release notes rendered as
/// markdown), and the install flow states.
struct UpdatePanel: View {
    let updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch updates.state {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…").appFont(12)
                }
                .padding(4)

            case .upToDate:
                Label("PorTree \(UpdateChecker.currentVersion) is up to date", systemImage: "checkmark.seal.fill")
                    .appFont(12, weight: .medium)
                    .foregroundStyle(.green)
                    .padding(4)

            case .available(let release):
                header(release)
                changelog(release)
                HStack(spacing: 8) {
                    Button {
                        updates.downloadAndInstall(release)
                    } label: {
                        Label("Download & Install", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("View on GitHub") { NSWorkspace.shared.open(release.htmlURL) }
                    Spacer()
                    Button("Skip This Version") { updates.skip(release) }
                        .foregroundStyle(.secondary)
                }
                .appFont(11.5)

            case .downloading(let release, _):
                header(release)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(release.assetName ?? "update")…").appFont(11.5)
                }

            case .installing(let release):
                header(release)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing — the app will relaunch…").appFont(11.5)
                }

            case .readyManual(let release, let url):
                header(release)
                changelog(release)
                Text("Running as a bare dev binary — no app bundle to replace. The new build is revealed in Finder.")
                    .appFont(10.5)
                    .foregroundStyle(.secondary)
                Button("Reveal Download") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .appFont(11.5)

            case .installedAwaitingRelaunch(let release):
                header(release)
                Label("Updated — the new version starts on next launch.", systemImage: "checkmark.seal.fill")
                    .appFont(11.5)
                    .foregroundStyle(.green)
                Button("Quit Now") { NSApp.terminate(nil) }.appFont(11.5)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .appFont(11.5)
                    .foregroundStyle(.orange)
                Button("Retry") { updates.checkManually() }.appFont(11.5)
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private func header(_ release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(release.title)
                .appFont(14, weight: .semibold)
            Text("\(release.version) — you are running \(UpdateChecker.currentVersion)"
                 + (release.assetBytes > 0 ? " · \(release.assetBytes / 1024 / 1024) MB" : ""))
                .appFont(10.5)
                .foregroundStyle(.secondary)
        }
    }

    private func changelog(_ release: UpdateChecker.Release) -> some View {
        ScrollView {
            Text(renderedChangelog(release.changelog))
                .appFont(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 280)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// GitHub release notes are markdown; inline-only parsing keeps the
    /// line structure (headings/bullets stay readable as plain lines).
    private func renderedChangelog(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
