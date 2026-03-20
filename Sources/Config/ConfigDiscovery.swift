import Foundation

struct DiscoveredConfig {
    let category: String
    let label: String
    let paths: [String]
    let sensitive: Bool
}

enum ConfigDiscovery {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func discover() -> [DiscoveredConfig] {
        var found: [DiscoveredConfig] = []
        let fm = FileManager.default

        for candidate in allCandidates {
            let existing = candidate.paths.filter { fm.fileExists(atPath: expand($0)) }
            if !existing.isEmpty {
                found.append(DiscoveredConfig(
                    category: candidate.category,
                    label: candidate.label,
                    paths: existing,
                    sensitive: candidate.sensitive
                ))
            }
        }
        return found
    }

    static func expand(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }

    static func contract(_ path: String) -> String {
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        if path == home {
            return "~"
        }
        return path
    }

    private static let allCandidates: [(category: String, label: String, paths: [String], sensitive: Bool)] = [
        // Shell
        ("Shell", "zsh", ["~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.zsh_history"], false),
        ("Shell", "bash", ["~/.bashrc", "~/.bash_profile", "~/.bash_history"], false),
        ("Shell", "fish", ["~/.config/fish"], false),

        // Git
        ("Git", "Git config", ["~/.gitconfig", "~/.gitignore_global"], false),

        // SSH (config only, no private keys)
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

        // Editors
        ("Editor", "Neovim", ["~/.config/nvim"], false),
        ("Editor", "Vim", ["~/.vimrc", "~/.vim"], false),
        ("Editor", "Emacs", ["~/.emacs.d"], false),
        ("Editor", "VS Code", ["~/Library/Application Support/Code/User/settings.json",
                                "~/Library/Application Support/Code/User/keybindings.json"], false),
        ("Editor", "Cursor", ["~/Library/Application Support/Cursor/User/settings.json",
                               "~/Library/Application Support/Cursor/User/keybindings.json"], false),
        ("Editor", "Sublime Text", ["~/Library/Application Support/Sublime Text/Packages/User"], false),

        // Dev tools
        ("Dev Tools", "starship", ["~/.config/starship.toml"], false),
        ("Dev Tools", "direnv", ["~/.config/direnv"], false),
        ("Dev Tools", "mise", ["~/.config/mise"], false),

        // Package managers (config only)
        ("Dev Tools", "Cargo config", ["~/.cargo/config.toml"], false),
        ("Dev Tools", "Homebrew Bundle", ["~/.Brewfile", "~/Brewfile"], false),

        // AI/LLM tools (full config dirs -- agents, settings, projects, instructions)
        ("AI Tools", "Claude CLI", ["~/.claude"], false),
        ("AI Tools", "GitHub Copilot", ["~/.config/github-copilot"], false),
        ("AI Tools", "Ollama config", ["~/.ollama/Modelfile"], false),

        // Cloud CLIs (config only, NOT credentials)
        ("Cloud", "AWS config", ["~/.aws/config"], true),
        ("Cloud", "GCP config", ["~/.config/gcloud/properties"], true),
        ("Cloud", "Azure config", ["~/.azure/config"], true),

        // Container tools (config only)
        ("Containers", "Docker config", ["~/.docker/config.json"], true),
    ]

    /// Paths that must NEVER be backed up (system/TCC-protected/daemon-managed)
    static let forbiddenPrefixes: [String] = [
        // TCC-protected user data (triggers tccd, may crash system)
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Safari",
        "~/Library/Suggestions",
        "~/Library/PersonalizationPortrait",
        // iCloud/cloud daemon-managed (touching crashes bird/tccd)
        "~/Library/Containers",
        "~/Library/Group Containers",
        "~/Library/Daemon Containers",
        "~/Library/CloudStorage",
        "~/Library/Mobile Documents",
        "~/Library/Application Support/CloudDocs",
        // System-managed data stores (Apple-proprietary, CCC also excludes)
        "~/Library/Application Support/com.apple.TCC",
        "~/Library/Application Support/MobileSync",
        "~/Library/Application Support/AddressBook",
        "~/Library/Metadata",
        "~/Library/Biome",
        "~/Library/DuetExpertCenter",
        "~/Library/IntelligencePlatform",
        "~/Library/StatusKit",
        "~/Library/Trial",
        // Caches/regenerable
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Saved Application State",
        "~/Library/Updates",
        // Photos/Music (synced via iCloud)
        "~/Pictures/Photos Library.photoslibrary",
        "~/Pictures/Photo Booth Library",
        "~/Music/Music/Media.localized",
        // System paths
        "/Library",
        "/System",
        "/etc",
        "/Applications",
        "/usr",
        "/opt",
        "/private",
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
