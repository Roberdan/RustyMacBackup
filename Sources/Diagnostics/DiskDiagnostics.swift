import Foundation

enum SpaceLevel {
    case verde
    case warning
    case rosso
}

enum DiskDiagnostics {
    static func preflightWriteTest(at url: URL) -> Bool {
        let probe = url.appendingPathComponent(".rustymacbackup-probe-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try "probe".write(to: probe, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    static func checkEncryption(volume: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("Encrypted: Yes") || output.contains("FileVault: Yes")
        } catch {
            return false
        }
    }

    static func diskSpace(at path: String) -> (free: UInt64, total: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber,
              let total = attrs[.systemSize] as? NSNumber
        else { return (0, 0) }
        return (free.uint64Value, total.uint64Value)
    }

    static func spaceColorLevel(free: UInt64) -> SpaceLevel {
        let gb50: UInt64 = 50 * 1_073_741_824
        let gb10: UInt64 = 10 * 1_073_741_824
        if free > gb50 { return .verde }
        if free > gb10 { return .warning }
        return .rosso
    }
}
