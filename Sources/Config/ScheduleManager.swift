import Foundation

struct ScheduleStatus {
    let installed: Bool
    let intervalMinutes: Int?
    let dailyHour: Int?
}

enum ScheduleManager {
    static let label = "com.roberdan.rusty-mac-backup"
    static let binaryPath = "/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup"

    static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/rusty-mac-backup/backup.log")
    }

    private static var errorLogPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/rusty-mac-backup/backup-error.log")
    }

    static func generatePlist(intervalSeconds: Int) -> String {
        generatePlistBody("""
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
        """)
    }

    static func generatePlistDaily(hour: Int) -> String {
        generatePlistBody("""
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>
                <integer>\(hour)</integer>
                <key>Minute</key>
                <integer>0</integer>
            </dict>
        """)
    }

    static func installSchedule(plistContent: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: plistPath.path) {
            _ = runLaunchctl(arguments: ["unload", plistPath.path])
        }
        try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
        let result = runLaunchctl(arguments: ["load", plistPath.path])
        guard result.status == 0 else {
            throw scheduleError("Failed to load schedule: \(result.stderr)")
        }
    }

    static func removeSchedule() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath.path) {
            let result = runLaunchctl(arguments: ["unload", plistPath.path])
            if result.status != 0 {
                let stderr = result.stderr.lowercased()
                if !stderr.contains("could not find specified service") && !stderr.contains("no such process") {
                    throw scheduleError("Failed to unload schedule: \(result.stderr)")
                }
            }
            try fm.removeItem(at: plistPath)
        }
    }

    static func scheduleStatus() -> ScheduleStatus {
        let installed = runLaunchctl(arguments: ["list", label]).status == 0
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil)
        }

        if let intervalSeconds = plist["StartInterval"] as? Int {
            return ScheduleStatus(installed: installed, intervalMinutes: intervalSeconds / 60, dailyHour: nil)
        }

        if let schedule = plist["StartCalendarInterval"] as? [String: Any],
           let hour = schedule["Hour"] as? Int {
            return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: hour)
        }

        return ScheduleStatus(installed: installed, intervalMinutes: nil, dailyHour: nil)
    }

    private static func generatePlistBody(_ scheduleBlock: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>backup</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>Nice</key>
            <integer>10</integer>
            <key>LowPriorityIO</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath.path)</string>
            <key>StandardErrorPath</key>
            <string>\(errorLogPath.path)</string>
            \(scheduleBlock)
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() } catch { return (1, "", error.localizedDescription) }
        process.waitUntilExit()

        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func scheduleError(_ message: String) -> NSError {
        NSError(domain: "ScheduleManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
