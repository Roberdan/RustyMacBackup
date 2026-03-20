import Foundation

struct DiscoveredConfig {
    let category: String
    let label: String
    let paths: [String]
    let sensitive: Bool
}

enum ConfigDiscovery {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Discover all installed dev tools by merging built-in + custom candidates.
    static func discover() -> [DiscoveredConfig] {
        var found: [DiscoveredConfig] = []
        let fm = FileManager.default
        let all = builtinCandidates + loadCustomCandidates()

        for candidate in all {
            // Filter out forbidden paths even if they exist
            let existing = candidate.paths.filter { fm.fileExists(atPath: expand($0)) && !isForbidden($0) }
            if !existing.isEmpty {
                found.append(DiscoveredConfig(
                    category: candidate.category,
                    label: candidate.label,
                    paths: existing,
                    sensitive: candidate.sensitive
                ))
            }
        }

        // Dynamic: discover individual Git repos in ~/GitHub, ~/Developer, ~/Projects
        for repoDir in ["~/GitHub", "~/Developer", "~/Projects"] {
            let expanded = expand(repoDir)
            guard fm.fileExists(atPath: expanded),
                  let contents = try? fm.contentsOfDirectory(atPath: expanded) else { continue }
            for name in contents.sorted() {
                let repoPath = expanded + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else { continue }
                // Skip hidden dirs and non-repo junk
                if name.hasPrefix(".") || name == "node_modules" { continue }
                let contracted = contract(repoPath)
                found.append(DiscoveredConfig(
                    category: "Repos",
                    label: name,
                    paths: [contracted],
                    sensitive: false
                ))
            }
        }

        return found
    }

    // MARK: - Path helpers

    static func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    static func contract(_ path: String) -> String {
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        if path == home { return "~" }
        return path
    }

    // MARK: - Custom discovery (user-defined, synced across machines)

    static var customDiscoveryPath: URL {
        URL(fileURLWithPath: ("~/.config/rusty-mac-backup/discovery-custom.toml" as NSString).expandingTildeInPath)
    }

    /// Load custom discovery entries from discovery-custom.toml
    private static func loadCustomCandidates() -> [Candidate] {
        guard let content = try? String(contentsOf: customDiscoveryPath, encoding: .utf8) else {
            return []
        }
        var candidates: [Candidate] = []
        var category = "Custom"
        var label = ""
        var paths: [String] = []
        var sensitive = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                // Save previous entry
                if !label.isEmpty && !paths.isEmpty {
                    candidates.append(Candidate(category: category, label: label,
                                                paths: paths, sensitive: sensitive))
                }
                label = String(line.dropFirst().dropLast())
                paths = []
                sensitive = false
                continue
            }

            if line.hasPrefix("category") {
                category = parseValue(line)
            } else if line.hasPrefix("path") && !line.hasPrefix("paths") {
                let p = parseValue(line)
                if !p.isEmpty { paths.append(p) }
            } else if line.hasPrefix("paths") {
                // inline array: paths = ["a", "b"]
                paths.append(contentsOf: parseArray(line))
            } else if line.hasPrefix("sensitive") {
                sensitive = parseValue(line) == "true"
            }
        }
        // Last entry
        if !label.isEmpty && !paths.isEmpty {
            candidates.append(Candidate(category: category, label: label,
                                        paths: paths, sensitive: sensitive))
        }
        return candidates
    }

    /// Generate a starter discovery-custom.toml with examples
    static func generateCustomTemplate() -> String {
        """
        # RustyMacBackup Custom Discovery
        # Add your own tools here. This file is backed up and works on any Mac.
        # Each [section] is a tool name. Paths use ~ for home directory.
        #
        # Example:
        # [My Tool]
        # category = Dev Tools
        # path = ~/.config/mytool
        # sensitive = false
        #
        # [Another Tool]
        # category = Cloud
        # paths = ["~/.config/another", "~/.another-rc"]
        # sensitive = true
        """
    }

    private static func parseValue(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if val.hasPrefix("\"") && val.hasSuffix("\"") {
            val = String(val.dropFirst().dropLast())
        }
        return val
    }

    private static func parseArray(_ line: String) -> [String] {
        guard let open = line.firstIndex(of: "["),
              let close = line.firstIndex(of: "]") else { return [] }
        let inner = String(line[line.index(after: open)..<close])
        return inner.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces)
                     .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Built-in candidates

    private typealias Candidate = (category: String, label: String, paths: [String], sensitive: Bool)

    private static let builtinCandidates: [Candidate] = [
        // Shell
        ("Shell", "zsh", ["~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.zsh_history"], false),
        ("Shell", "bash", ["~/.bashrc", "~/.bash_profile", "~/.bash_history"], false),
        ("Shell", "fish", ["~/.config/fish"], false),

        // Git
        ("Git", "Git config", ["~/.gitconfig", "~/.gitignore_global", "~/.config/git"], false),

        // SSH (config + public keys, NOT private keys by default)
        ("SSH", "SSH config", ["~/.ssh/config", "~/.ssh/known_hosts"], false),

        // Terminal emulators
        ("Terminal", "Ghostty", ["~/.config/ghostty"], false),
        ("Terminal", "Warp", ["~/Library/Application Support/Warp"], false),
        ("Terminal", "iTerm2", ["~/Library/Application Support/iTerm2"], false),
        ("Terminal", "Alacritty", ["~/.config/alacritty"], false),
        ("Terminal", "kitty", ["~/.config/kitty"], false),

        // Multiplexers
        ("Terminal", "tmux", ["~/.tmux.conf", "~/.config/tmux"], false),
        ("Terminal", "zellij", ["~/.config/zellij"], false),

        // Editors (no Neovim/Helix -- add via custom discovery if needed)
        ("Editor", "Vim", ["~/.vimrc", "~/.vim"], false),
        ("Editor", "VS Code settings", ["~/Library/Application Support/Code/User/settings.json",
                                          "~/Library/Application Support/Code/User/keybindings.json"], false),
        ("Editor", "VS Code extensions", ["~/.vscode/extensions"], false),
        ("Editor", "Cursor settings", ["~/Library/Application Support/Cursor/User/settings.json",
                                         "~/Library/Application Support/Cursor/User/keybindings.json"], false),
        ("Editor", "Cursor extensions", ["~/.cursor/extensions"], false),
        ("Editor", "Zed", ["~/.config/zed"], false),
        ("Editor", "Xcode UserData", ["~/Library/Developer/Xcode/UserData"], false),
        ("Editor", "Xcode Provisioning", ["~/Library/MobileDevice/Provisioning Profiles"], false),

        // AI/LLM tools
        // Claude CLI -- specific safe subdirs only (full ~/.claude/ is 16 GB+)
        ("AI Tools", "Claude CLI settings", ["~/.claude/settings.json", "~/.claude/settings.local.json"], false),
        ("AI Tools", "Claude CLI agents", ["~/.claude/agents"], false),
        ("AI Tools", "Claude CLI memory", ["~/.claude/agent-memory"], false),
        ("AI Tools", "Claude CLI projects", ["~/.claude/projects"], false),
        ("AI Tools", "Claude AGENTS.md", ["~/.claude/AGENTS.md"], false),
        ("AI Tools", "Claude plans DB", ["~/.claude/data/plan-db.sqlite", "~/.claude/plans"], false),
        ("AI Tools", "Claude scripts", ["~/.claude/scripts"], false),
        ("AI Tools", "GitHub Copilot", ["~/.config/github-copilot"], false),
        ("AI Tools", "gh-copilot", ["~/.config/gh-copilot"], false),
        ("AI Tools", "OpenAI", ["~/.config/openai"], false),
        ("AI Tools", "Goose", ["~/.config/goose"], false),
        ("AI Tools", "shell_gpt", ["~/.config/shell_gpt"], false),

        // Dev tools
        ("Dev Tools", "oh-my-posh", ["~/.config/oh-my-posh"], false),
        ("Dev Tools", "starship", ["~/.config/starship.toml"], false),
        ("Dev Tools", "direnv", ["~/.config/direnv"], false),
        ("Dev Tools", "mise", ["~/.config/mise"], false),
        ("Dev Tools", "btop", ["~/.config/btop"], false),
        ("Dev Tools", "gitui", ["~/.config/gitui"], false),
        ("Dev Tools", "yazi", ["~/.config/yazi"], false),
        ("Dev Tools", "Cargo config", ["~/.cargo/config.toml"], false),
        ("Dev Tools", "uv (Python)", ["~/.config/uv"], false),
        ("Dev Tools", "Homebrew Bundle", ["~/.Brewfile", "~/Brewfile"], false),

        // Auth & Tokens -- separate from config so user can toggle independently
        ("Auth", "GitHub CLI auth", ["~/.config/gh/hosts.yml"], true),
        ("Auth", "SSH private keys", ["~/.ssh/id_ed25519", "~/.ssh/id_rsa",
                                       "~/.ssh/id_ed25519_innersource",
                                       "~/.ssh/id_ed25519_microsoft"], true),
        ("Auth", "npm auth", ["~/.npmrc"], true),
        ("Auth", "Cargo auth", ["~/.cargo/credentials.toml"], true),
        ("Auth", "Docker auth", ["~/.docker/config.json"], true),
        ("Auth", "AWS credentials", ["~/.aws/credentials"], true),
        ("Auth", "Azure tokens", ["~/.azure/azureProfile.json", "~/.azure/az.sess"], true),
        ("Auth", "GCP credentials", ["~/.config/gcloud/application_default_credentials.json"], true),
        ("Auth", "Stripe auth", ["~/.config/stripe/config.toml"], true),
        ("Auth", "VS Code auth", ["~/Library/Application Support/Code/User/globalStorage/github.login"], true),
        ("Auth", "Cursor auth", ["~/Library/Application Support/Cursor/User/globalStorage/github.login"], true),

        // Cloud CLIs (config only, NOT credentials)
        ("Cloud", "AWS config", ["~/.aws/config"], false),
        ("Cloud", "GCP config", ["~/.config/gcloud/properties"], false),
        ("Cloud", "Azure config", ["~/.azure/config"], false),
        ("Cloud", "Stripe config", ["~/.config/stripe"], false),
        ("Cloud", "Tailscale prefs", ["~/Library/Preferences/io.tailscale.ipn.macos.plist",
                                       "~/Library/Application Support/Tailscale"], false),

        // macOS Preferences (safe plist files -- read-only copies)
        ("macOS", "Keyboard shortcuts", ["~/Library/Preferences/com.apple.symbolichotkeys.plist"], false),
        ("macOS", "Global preferences", ["~/Library/Preferences/.GlobalPreferences.plist"], false),
        ("macOS", "Dock layout", ["~/Library/Preferences/com.apple.dock.plist"], false),
        ("macOS", "Finder settings", ["~/Library/Preferences/com.apple.finder.plist"], false),
        ("macOS", "Terminal.app", ["~/Library/Preferences/com.apple.Terminal.plist"], false),
        ("macOS", "Custom dictionary", ["~/Library/Spelling/LocalDictionary"], false),
        ("macOS", "Custom fonts", ["~/Library/Fonts"], false),
    ]

    // MARK: - Restore discovery

    /// Returns candidates whose paths are present in the given snapshot.
    /// Unlike discover(), does NOT require files to exist on the current machine —
    /// safe for cross-machine restore (fresh Mac).
    static func candidatesForRestore(snapshotTopLevels: Set<String>) -> [DiscoveredConfig] {
        var found: [DiscoveredConfig] = []
        for candidate in builtinCandidates {
            let inSnapshot = candidate.paths.filter { path in
                let rel = path.hasPrefix("~/") ? String(path.dropFirst(2)) : path
                let top: String
                if let slash = rel.firstIndex(of: "/") {
                    top = String(rel[rel.startIndex..<slash])
                } else {
                    top = rel
                }
                return snapshotTopLevels.contains(top)
            }
            if !inSnapshot.isEmpty {
                found.append(DiscoveredConfig(category: candidate.category, label: candidate.label,
                                              paths: inSnapshot, sensitive: candidate.sensitive))
            }
        }
        return found
    }

    // MARK: - Forbidden paths

    static let forbiddenPrefixes: [String] = [
        // TCC-protected user data (triggers tccd, may crash system)
        "~/Library/Mail", "~/Library/Messages", "~/Library/Safari",
        "~/Library/Suggestions", "~/Library/PersonalizationPortrait",
        // iCloud/cloud daemon-managed (touching crashes bird/tccd)
        "~/Library/Containers", "~/Library/Group Containers",
        "~/Library/Daemon Containers", "~/Library/CloudStorage",
        "~/Library/Mobile Documents", "~/Library/Application Support/CloudDocs",
        // System-managed data stores
        "~/Library/Application Support/com.apple.TCC",
        "~/Library/Application Support/MobileSync",
        "~/Library/Application Support/AddressBook",
        "~/Library/Metadata", "~/Library/Biome",
        "~/Library/DuetExpertCenter", "~/Library/IntelligencePlatform",
        "~/Library/StatusKit", "~/Library/Trial",
        // Caches/regenerable
        "~/Library/Caches", "~/Library/Logs",
        "~/Library/Saved Application State", "~/Library/Updates",
        // Photos/Music
        "~/Pictures/Photos Library.photoslibrary",
        "~/Pictures/Photo Booth Library",
        "~/Music/Music/Media.localized",
        // Claude CLI build artifacts (16 GB+)
        "~/.claude/rust", "~/.claude/debug", "~/.claude/worktrees",
        "~/.claude/node_modules", "~/.claude/file-history",
        "~/.claude/data", "~/.claude/scripts", "~/.claude/backups",
        "~/.claude/logs", "~/.claude/.copilot-tracking",
        // System paths
        "/Library", "/System", "/etc", "/Applications", "/usr", "/opt", "/private",
    ]

    static func isForbidden(_ path: String) -> Bool {
        let expanded = expand(path)
        for prefix in forbiddenPrefixes {
            let expandedPrefix = expand(prefix)
            if expanded == expandedPrefix || expanded.hasPrefix(expandedPrefix + "/") {
                return true
            }
        }
        return false
    }
}
