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
        out.append("path = \"\(Self.escape(source.path))\"")
        out.append("extra_paths = [")
        for path in source.extraPaths {
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

        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func parseTOML(_ content: String) throws -> Config {
        var config = Config(
            source: SourceConfig(path: "", extraPaths: []),
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

        return config
    }

    private static func assign(section: String, key: String, stringValue: String, to config: inout Config) {
        switch "\(section).\(key)" {
        case "source.path": config.source.path = stringValue
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
        case "source.extra_paths": config.source.extraPaths = values
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
            if escaped {
                token.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                token.append(char)
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                token.append(char)
                if !inQuotes, let parsed = parseQuotedString(token) {
                    items.append(parsed)
                    token = ""
                }
                continue
            }
            if inQuotes {
                token.append(char)
            }
        }
        return items
    }

    private static func stripComment(from line: String) -> String {
        var out = ""
        var inQuotes = false
        var escaped = false

        for char in line {
            if escaped {
                out.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                out.append(char)
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                out.append(char)
                continue
            }
            if char == "#", !inQuotes {
                break
            }
            out.append(char)
        }
        return out
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct SourceConfig {
    var path: String
    var extraPaths: [String]

    func allPaths() -> [String] {
        return [path] + extraPaths
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

func generateDefaultConfig(homePath: String, backupPath: String) -> String {
    let extraPaths = ["/Applications", "/opt/homebrew", "/usr/local", "/etc", "/Library"]
    let patterns = [".Spotlight-*", ".fseventsd", ".Trash", ".Trashes", ".DS_Store", ".TemporaryItems",
                    ".VolumeIcon.icns", "Library/Caches", "Library/Logs", "Library/Application Support/Caches",
                    "Library/Saved Application State", "Library/Containers/*/Data/Library/Caches",
                    "Library/Updates", "Library/Developer", "OneDrive*", "Library/CloudStorage",
                    "Library/Mobile Documents", "Library/Group Containers/*.Office", "Dropbox",
                    "Google Drive", "iCloud Drive*", "node_modules", ".git/objects", "target/debug",
                    "target/release", ".build", "*.tmp", "*.swp", ".cache", "__pycache__", ".venv",
                    ".tox", ".ollama/models", ".lmstudio", "*.iso", "*.dmg",
                    "Pictures/Photos Library.photoslibrary", "Pictures/Photo Booth Library",
                    "Music/Music/Media.localized", "Library/Application Support/MobileSync"]

    var lines = ["[source]", "path = \"\(homePath)\"", "extra_paths = ["]
    extraPaths.forEach { lines.append("    \"\($0)\",") }
    lines.append(contentsOf: ["]", "", "[destination]", "path = \"\(backupPath)\"", "", "[exclude]", "patterns = ["])
    patterns.forEach { lines.append("    \"\($0)\",") }
    lines.append(contentsOf: ["]", "", "[retention]", "hourly = 24", "daily = 30", "weekly = 52", "monthly = 0", ""])
    return lines.joined(separator: "\n")
}
