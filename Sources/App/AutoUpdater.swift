import Foundation
import AppKit

enum AutoUpdater {
    static let repoSlug = "roberdan/RustyMacBackup"

    struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    // MARK: - Check

    /// Returns the latest version string if newer than the running bundle, else nil.
    static func checkForUpdate() async -> String? {
        guard Bundle.main.bundleIdentifier != nil else { return nil } // skip dev builds
        let apiURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            return isNewer(latest, than: current) ? latest : nil
        } catch {
            Log.info("Update check failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Download & Install

    /// Downloads the .app.zip for `version`, rsync-replaces the running app in-place, then relaunches.
    /// In-place replacement preserves macOS Full Disk Access permissions.
    static func downloadAndInstall(version: String) async throws {
        let zipName = "RustyMacBackup-\(version).app.zip"
        let downloadURL = URL(string: "https://github.com/\(repoSlug)/releases/download/v\(version)/\(zipName)")!

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RustyMacBackup-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        Log.info("Downloading \(zipName)…")
        let zipPath = tempDir.appendingPathComponent(zipName)
        let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
        try FileManager.default.moveItem(at: localURL, to: zipPath)

        Log.info("Unzipping…")
        try shell("/usr/bin/unzip", ["-q", zipPath.path, "-d", tempDir.path])

        let newApp = tempDir.appendingPathComponent("RustyMacBackup.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw UpdateError.badZip
        }

        let currentApp = Bundle.main.bundleURL

        Log.info("Installing in-place over \(currentApp.path)…")
        // rsync replaces Contents without changing the .app path → FDA preserved
        try shell("/usr/bin/rsync", [
            "-a", "--delete",
            newApp.appendingPathComponent("Contents").path + "/",
            currentApp.appendingPathComponent("Contents").path + "/"
        ])

        Log.info("Update complete — relaunching")
        DispatchQueue.main.async {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(Bundle.main.bundleURL, configuration: cfg, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
        }
    }

    // MARK: - Helpers

    private static func shell(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.processFailed(exe, p.terminationStatus) }
    }

    static func isNewer(_ v1: String, than v2: String) -> Bool {
        let a = v1.split(separator: ".").compactMap { Int($0) }
        let b = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: LocalizedError {
        case badZip
        case processFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .badZip: return "Il file di aggiornamento non è valido"
            case .processFailed(let cmd, let code): return "\(cmd) fallito con codice \(code)"
            }
        }
    }
}
