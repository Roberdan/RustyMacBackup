import Foundation

struct Config {
    var source: SourceConfig
    var destination: DestinationConfig
    var exclude: ExcludeConfig
    var retention: RetentionConfig

    static var defaultPath: URL {
        URL(fileURLWithPath: ("~/.config/rusty-mac-backup/config.toml" as NSString).expandingTildeInPath)
    }

    static func load(from url: URL) throws -> Config {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseTOML(content)
    }

    func save(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var out: [String] = []
        out.append("[source]")
        out.append("paths = [")
        for path in source.paths {
            out.append("    \"\(Self.escape(path))\",")
        }
        out.append("]")
        out.append("")
        out.append("[destination]")
        out.append("path = \"\(Self.escape(destination.path))\"")
        out.append("")
        out.append("[exclude]")
        out.append("patterns = [")
        for pattern in exclude.patterns {
            out.append("    \"\(Self.escape(pattern))\",")
        }
        out.append("]")
        out.append("")
        out.append("[retention]")
        out.append("hourly = \(retention.hourly)")
        out.append("daily = \(retention.daily)")
        out.append("weekly = \(retention.weekly)")
        out.append("monthly = \(retention.monthly)")
        out.append("")

        let data = out.joined(separator: "\n").data(using: .utf8)!
        try data.write(to: url, options: [.atomic])
        // Set config permissions to 0600 (owner-only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func parseTOML(_ content: String) throws -> Config {
        var config = Config(
            source: SourceConfig(paths: []),
            destination: DestinationConfig(path: ""),
            exclude: ExcludeConfig(patterns: []),
            retention: RetentionConfig()
        )

        var currentSection = ""
        var arrayState: (section: String, key: String, values: [String])?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if var state = arrayState {
                if let closeIdx = line.firstIndex(of: "]") {
                    let beforeClose = String(line[..<closeIdx])
                    state.values.append(contentsOf: parseArrayItems(from: beforeClose))
                    assign(section: state.section, key: state.key, values: state.values, to: &config)
                    arrayState = nil
                } else {
                    state.values.append(contentsOf: parseArrayItems(from: line))
                    arrayState = state
                }
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("[") {
                let afterOpen = String(value.dropFirst())
                if let closeIndex = afterOpen.firstIndex(of: "]") {
                    let inner = String(afterOpen[..<closeIndex])
                    let values = parseArrayItems(from: inner)
                    assign(section: currentSection, key: key, values: values, to: &config)
                } else {
                    let initial = parseArrayItems(from: afterOpen)
                    arrayState = (section: currentSection, key: key, values: initial)
                }
                continue
            }

            if let str = parseQuotedString(value) {
                assign(section: currentSection, key: key, stringValue: str, to: &config)
            } else if let intValue = UInt32(value) {
                assign(section: currentSection, key: key, intValue: intValue, to: &config)
            }
        }

        // Migrate old format: if paths is empty but we got a legacy "path" + "extra_paths"
        if config.source.paths.isEmpty, let legacy = config.source.legacyPath {
            config.source.paths = [legacy] + config.source.legacyExtraPaths
            config.source.legacyPath = nil
            config.source.legacyExtraPaths = []
        }

        return config
    }

    private static func assign(section: String, key: String, stringValue: String, to config: inout Config) {
        switch "\(section).\(key)" {
        case "source.path": config.source.legacyPath = stringValue
        case "destination.path": config.destination.path = stringValue
        default: break
        }
    }

    private static func assign(section: String, key: String, intValue: UInt32, to config: inout Config) {
        switch "\(section).\(key)" {
        case "retention.hourly": config.retention.hourly = intValue
        case "retention.daily": config.retention.daily = intValue
        case "retention.weekly": config.retention.weekly = intValue
        case "retention.monthly": config.retention.monthly = intValue
        default: break
        }
    }

    private static func assign(section: String, key: String, values: [String], to config: inout Config) {
        switch "\(section).\(key)" {
        case "source.paths": config.source.paths = values
        case "source.extra_paths": config.source.legacyExtraPaths = values
        case "exclude.patterns": config.exclude.patterns = values
        default: break
        }
    }

    private static func parseQuotedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseArrayItems(from input: String) -> [String] {
        var items: [String] = []
        var inQuotes = false
        var escaped = false
        var token = ""
        for char in input {
            if escaped { token.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; token.append(char); continue }
            if char == "\"" {
                inQuotes.toggle()
                token.append(char)
                if !inQuotes, let parsed = parseQuotedString(token) {
                    items.append(parsed)
                    token = ""
                }
                continue
            }
            if inQuotes { token.append(char) }
        }
        return items
    }

    private static func stripComment(from line: String) -> String {
        var out = ""
        var inQuotes = false
        var escaped = false
        for char in line {
            if escaped { out.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; out.append(char); continue }
            if char == "\"" { inQuotes.toggle(); out.append(char); continue }
            if char == "#", !inQuotes { break }
            out.append(char)
        }
        return out
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct SourceConfig {
    var paths: [String]
    // Legacy migration support
    var legacyPath: String?
    var legacyExtraPaths: [String] = []

    func allExpandedPaths() -> [String] {
        paths.map { ConfigDiscovery.expand($0) }
    }
}

struct DestinationConfig {
    var path: String
}

struct ExcludeConfig {
    var patterns: [String]
}

struct RetentionConfig {
    var hourly: UInt32 = 24
    var daily: UInt32 = 30
    var weekly: UInt32 = 52
    var monthly: UInt32 = 0
}

func generateDefaultConfig(backupPath: String) -> Config {
    let discovered = ConfigDiscovery.discover()
    var paths: [String] = []
    for item in discovered where !item.sensitive {
        for path in item.paths where !ConfigDiscovery.isForbidden(path) {
            paths.append(path)
        }
    }
    // Always include the backup config itself (for portability)
    paths.append("~/.config/rusty-mac-backup")

    // Add ~/GitHub if it exists
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if FileManager.default.fileExists(atPath: home + "/GitHub") {
        paths.append("~/GitHub")
    }
    if FileManager.default.fileExists(atPath: home + "/Developer") {
        paths.append("~/Developer")
    }

    let defaultExcludes = [
        // macOS system junk (CCC-recommended exclusions)
        ".DS_Store", ".Trash", ".Trashes", ".Spotlight-V100",
        ".fseventsd", ".TemporaryItems", ".VolumeIcon.icns",
        "DocumentRevisions-V100",
        // Dev build artifacts (regenerable)
        "node_modules", ".git/objects", "target/debug", "target/release",
        ".build", "*.tmp", "*.swp", ".cache", "__pycache__", ".venv", ".tox",
        // App caches inside backed-up dirs
        "Caches", "Cache", "GPUCache", "ShaderCache", "Code Cache",
        "CachedData", "CachedExtensions", "CachedExtensionVSIXs",
        // Large binaries
        "*.iso", "*.dmg",
        // Claude CLI internals (16 GB+ of build artifacts, debug data, etc.)
        "rust", "debug", "worktrees", "file-history", "data",
        "scripts", ".copilot-tracking",
        // AI tool caches and databases (regenerable)
        "embedding-cache.db", "embedding-cache.db-shm", "embedding-cache.db-wal",
        "session-store.db", "session-store.db-shm", "session-store.db-wal",
        "session.db", "marketplace-cache",
        "*.jsonl",
        // Logs everywhere
        "logs", "*.log",
        // AI models (huge, re-downloadable)
        ".ollama/models", ".lmstudio",
    ]

    return Config(
        source: SourceConfig(paths: paths),
        destination: DestinationConfig(path: backupPath),
        exclude: ExcludeConfig(patterns: defaultExcludes),
        retention: RetentionConfig()
    )
}
