import AppKit
import Observation

/// Checks GitHub for a newer release and offers to open its download page. Simpler to
/// maintain than Sparkle: no signing keys or appcast, just a tagged GitHub Release.
@MainActor
@Observable
final class UpdateChecker {
    static let repository = "RohanReddyBandi/Glasstap"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    private(set) var isChecking = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let name: String?
    }

    /// Checks once a day when automatic checks are on. Stays quiet unless there's an update.
    func checkInBackgroundIfDue(settings: AppSettings) {
        guard settings.autoCheckForUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        Task { await check(userInitiated: false, settings: settings) }
    }

    func check(userInitiated: Bool, settings: AppSettings) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Glasstap/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            settings.lastUpdateCheck = Date()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                if userInitiated { inform("You're up to date", "Glasstap \(Self.currentVersion) is the latest version.") }
                return
            }
            guard status == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let latest = SemanticVersion(release.tag_name),
                  let current = SemanticVersion(Self.currentVersion)
            else { throw URLError(.cannotParseResponse) }

            if latest > current {
                offer(release, version: latest.description)
            } else if userInitiated {
                inform("You're up to date", "Glasstap \(Self.currentVersion) is the latest version.")
            }
        } catch {
            if userInitiated {
                inform("Couldn't check for updates", "Check your internet connection, or see the releases page on GitHub.")
            }
        }
    }

    private func offer(_ release: Release, version: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Glasstap \(version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Download the new version from GitHub, then drag it into Applications to replace this one."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.html_url)
        }
    }

    private func inform(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
