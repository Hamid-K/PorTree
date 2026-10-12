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

    /// The notes area has a FIXED height: a scroll view with only a maximum
    /// collapses to a sliver when the popover is measured before its toolbar
    /// anchor has laid out (auto-open at launch), hiding the notes entirely.
    private func changelog(_ release: UpdateChecker.Release) -> some View {
        ScrollView {
            ReleaseNotesView(markdown: release.changelog)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 260)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Markdown release notes as real blocks: bold headings, bulleted items,
/// muted quotes, wrapped paragraphs — inline bold/code/links preserved.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(markdown)
        VStack(alignment: .leading, spacing: 5) {
            if blocks.isEmpty {
                Text("No release notes for this version.")
                    .appFont(11)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .appFont(12, weight: .semibold)
                        .padding(.top, index == 0 ? 0 : 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").appFont(11).foregroundStyle(.secondary)
                        Text(inline(text)).appFont(11)
                    }
                case .quote(let text):
                    Text(inline(text))
                        .appFont(10.5)
                        .italic()
                        .foregroundStyle(.secondary)
                case .paragraph(let text):
                    Text(inline(text)).appFont(11)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
