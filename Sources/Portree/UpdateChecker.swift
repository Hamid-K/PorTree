import SwiftUI
import AppKit
import PortreeCore

/// In-app updater — no daemon, no framework. On launch (and on demand) it
/// asks the GitHub Releases API for the latest release, shows the CHANGELOG
/// in a popover, and on consent downloads the zip, swaps the app bundle in
/// place and relaunches. Running as a bare dev binary (no .app bundle), it
/// reveals the downloaded build instead of self-replacing.
@MainActor
@Observable
final class UpdateChecker {

    // Single source of truth for the app version — make-app.sh greps this
    // line into CFBundleShortVersionString at package time.
    static let fallbackVersion = "1.3.1"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }

    struct Release: Equatable {
        let version: String        // tag, e.g. "v1.3.0"
        let title: String
        let changelog: String      // release notes body (markdown)
        let htmlURL: URL
        let assetURL: URL?
        let assetName: String?
        let assetBytes: Int64
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case readyManual(Release, downloadedAt: URL)  // dev binary / translocated: no self-replace
        case installedAwaitingRelaunch(Release)       // swap done, auto-relaunch failed
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Toolbar panel visibility — opened automatically when an update is
    /// found, or by the manual "Check for Updates…" command.
    var panelShown = false
    /// A failed AUTOMATIC check stays silent (offline launch must not grow
    /// a pulsing badge); a failed manual check shows its error.
    private(set) var lastCheckManual = false

    var autoCheckEnabled = true {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: "portree.updates.auto") }
    }
    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "portree.updates.skipped") }
        set { UserDefaults.standard.set(newValue, forKey: "portree.updates.skipped") }
    }

    init() {
        autoCheckEnabled = UserDefaults.standard.object(forKey: "portree.updates.auto") as? Bool ?? true
    }

    /// The toolbar shows the update button only when there is something to
    /// say (never for silent up-to-date auto-checks).
    var hasNews: Bool {
        switch state {
        case .available, .downloading, .installing, .readyManual, .installedAwaitingRelaunch: return true
        case .failed: return lastCheckManual
        case .idle, .checking, .upToDate: return false
        }
    }

    func checkOnLaunch() {
        guard autoCheckEnabled else { return }
        Task { await check(manual: false) }
    }

    func checkManually() {
        panelShown = true
        Task { await check(manual: true) }
    }

    /// `--check-updates`: run one check and print the outcome to stdout.
    func checkHeadless() async {
        await check(manual: true)
        let out: String
        switch state {
        case .available(let release):
            out = "update available: \(release.version) (running \(Self.currentVersion))\n"
                + "asset: \(release.assetName ?? "none") (\(release.assetBytes) bytes)\n"
                + "changelog:\n\(release.changelog)"
        case .upToDate:
            out = "up to date (\(Self.currentVersion))"
        case .failed(let message):
            out = message
        default:
            out = "unexpected state"
        }
        FileHandle.standardOutput.write(Data((out + "\n").utf8))
    }

    /// Only release-asset hosts may supply the replacement binary — a forged
    /// API response (TLS-inspection proxy, rogue root CA) must not be able to
    /// point the installer at an arbitrary server. Defense-in-depth: the app
    /// is ad-hoc signed, so there is no payload signature to verify; this
    /// allowlist forces an attacker to intercept GitHub's own hosts too.
    private static let assetHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    private static let releasesPage = URL(string: "https://github.com/Hamid-K/PorTree/releases")!

    private static func validatedAssetURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", let host = url.host(), assetHosts.contains(host) else { return nil }
        return url
    }

    private static func validatedPageURL(_ url: URL) -> URL {
        (url.scheme == "https" && url.host() == "github.com") ? url : releasesPage
    }

    private func check(manual: Bool) async {
        if case .downloading = state { return }
        if case .installing = state { return }
        lastCheckManual = manual
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/Hamid-K/PorTree/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            struct APIRelease: Decodable {
                struct Asset: Decodable {
                    let name: String
                    let browser_download_url: URL
                    let size: Int64
                }
                let tag_name: String
                let name: String?
                let body: String?
                let html_url: URL
                let assets: [Asset]
            }
            let api = try JSONDecoder().decode(APIRelease.self, from: data)
            let zip = api.assets.first {
                $0.name.hasSuffix(".zip") && Self.validatedAssetURL($0.browser_download_url) != nil
            }
            let release = Release(
                version: api.tag_name,
                title: api.name ?? api.tag_name,
                changelog: api.body ?? "No release notes.",
                htmlURL: Self.validatedPageURL(api.html_url),
                assetURL: Self.validatedAssetURL(zip?.browser_download_url),
                assetName: zip?.name,
                assetBytes: zip?.size ?? 0
            )
            if Format.compareVersions(release.version, Self.currentVersion) > 0 {
                if !manual, skippedVersion == release.version {
                    // Skipped versions stay silent across relaunches; a
                    // manual check still surfaces them.
                    state = .upToDate
                    return
                }
                state = .available(release)
                panelShown = true
                if !manual {
                    AppStore.shared.appendEvent(EventRow(
                        kind: .info,
                        title: "Update available — PorTree \(release.version)",
                        detail: "running \(Self.currentVersion) · changelog in the update panel"
                    ))
                }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("update check failed: \(error.localizedDescription)")
            if !manual { panelShown = false }
        }
    }

    func skip(_ release: Release) {
        skippedVersion = release.version
        panelShown = false
        state = .upToDate
    }

    /// Download the release zip and swap this app bundle for the new one.
    /// The zip comes over HTTPS from the pinned repo's release assets; the
    /// app is ad-hoc signed, so there is no stronger signature to verify —
    /// stated honestly rather than pretended otherwise.
    func downloadAndInstall(_ release: Release) {
        guard let assetURL = release.assetURL else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        state = .downloading(release, progress: 0)
        Task {
            var swapped = false
            do {
                let (tempFile, response) = try await URLSession.shared.download(from: assetURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                // Free integrity check: the API told us the asset's size —
                // a truncated download or proxy interstitial must not reach
                // the bundle swap.
                let downloadedBytes = (try? FileManager.default
                    .attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
                guard release.assetBytes <= 0 || downloadedBytes == release.assetBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("portree-update-\(release.version)", isDirectory: true)
                try? FileManager.default.removeItem(at: workDir)
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let zipFile = workDir.appendingPathComponent(release.assetName ?? "update.zip")
                try FileManager.default.moveItem(at: tempFile, to: zipFile)

                state = .installing(release)
                try await run("/usr/bin/ditto", ["-xk", zipFile.path, workDir.path])
                guard let newApp = try FileManager.default
                    .contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // Clear quarantine in case the zip carried it.
                try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

                let bundleURL = Bundle.main.bundleURL
                // Gatekeeper App Translocation runs the app from a read-only
                // mount — replacing that clone is impossible AND pointless
                // (the real copy lives wherever the user unzipped it).
                let translocated = bundleURL.path.contains("/AppTranslocation/")
                guard bundleURL.pathExtension == "app", !translocated else {
                    // Dev binary or translocated — hand the user the build.
                    state = .readyManual(release, downloadedAt: newApp)
                    NSWorkspace.shared.activateFileViewerSelecting([newApp])
                    return
                }
                _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newApp)
                swapped = true
                AppStore.shared.appendEvent(EventRow(
                    kind: .info,
                    title: "Updated to PorTree \(release.version)",
                    detail: "relaunching"
                ))
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
                NSApp.terminate(nil)
            } catch {
                // After a successful swap the install DID happen — a relaunch
                // hiccup must not read as failure (or re-offer the update).
                state = swapped
                    ? .installedAwaitingRelaunch(release)
                    : .failed("install failed: \(error.localizedDescription)")
            }
        }
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
