# RustyMacBackup

Safe, fast backup of your dev configurations and chosen folders. A Time Machine alternative that works with MDM-restricted Macs.

**Whitelist-only model** -- backs up ONLY the folders you choose. No system paths, no TCC conflicts, no Full Disk Access needed.

## Features

- **Safe by design** -- whitelist-only, forbidden path enforcement, no system directory access
- **Auto-discovery** -- detects installed dev tools (shells, editors, terminals, Git, SSH, etc.)
- **Incremental backups** with hard links (unchanged files = zero extra space)
- **APFS clone support** -- instant file copies via `copyfile()` with `COPYFILE_CLONE`
- **Parallel I/O** -- 8 concurrent workers via Swift `TaskGroup`
- **SwiftUI tree view** -- collapsible categories (Shell, Git, SSH, Terminal, Editor, AI Tools, Auth, Cloud, macOS, Repos) with tri-state checkboxes
- **Auto-update** -- checks GitHub releases on launch, downloads and installs in-place preserving FDA permissions
- **Battery-aware** -- throttles I/O on battery, full speed on AC
- **Symlink-safe** -- skips symbolic links to prevent loops and indirect TCC access
- **Scheduled backups** -- via macOS LaunchAgent
- **CLI + menu bar** -- single .app bundle, zero dependencies

## What It Backs Up

Auto-discovered dev tool configs (run `discover` to see yours):

| Category | Tools |
|----------|-------|
| Shell | zsh, bash, fish |
| Git | .gitconfig, .gitignore_global |
| SSH | config, known_hosts (NOT private keys) |
| Terminal | Ghostty, Warp, iTerm2, Alacritty, kitty |
| Multiplexer | tmux, zellij |
| Editor | Neovim, Vim, Emacs, VS Code, Cursor, Sublime Text |
| Dev Tools | starship, direnv, mise, Cargo config, Brewfile |
| AI Tools | Claude CLI settings, Ollama config |
| Custom | Any folder you add (~/GitHub, ~/Documents, etc.) |

## What It Will NEVER Touch

System/TCC-protected paths are hardcoded as forbidden:

`Library/Mail`, `Library/Messages`, `Library/Safari`, `Library/Containers`,
`Library/CloudStorage`, `Library/Mobile Documents`, `Library/Caches`,
`/Library`, `/System`, `/etc`, `/Applications`, `/usr`, `/opt`, `/private`

## Installation

```bash
git clone https://github.com/Roberdan/RustyMacBackup.git
cd RustyMacBackup
./install.sh          # builds + installs in-place to /Applications (FDA preserved)
```

Or download `RustyMacBackup-2.0.0-arm64.pkg` from [Releases](https://github.com/Roberdan/RustyMacBackup/releases) and double-click.

**Requirements**: macOS 14+ (Sonoma), Xcode Command Line Tools

## Auto-Update

The app checks GitHub releases 5 seconds after launch. When a new version is available, a blue banner appears in the popover — click **Aggiorna** to download and install in-place (no FDA permission loss).

## Quick Start

```bash
alias rustyback='/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup'

# See what dev configs are detected on your Mac
rustyback discover

# First-time setup (picks disk, auto-discovers configs)
rustyback init

# Run a backup
rustyback backup

# Check status
rustyback status
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `discover` | Show detected dev tool configs |
| `init` | Setup wizard (discovers configs, picks disk) |
| `backup` | Run backup now |
| `stop` | Stop running backup |
| `status` | Show backup status + folder list |
| `list` | List backup snapshots |
| `prune [--dry-run]` | Clean up old backups |
| `restore <snapshot> [path] --to <dest>` | Restore from backup |
| `config show\|add\|remove\|edit` | Manage backed-up paths |
| `schedule on\|off\|interval <min>\|daily <hour>` | Manage schedule |
| `errors [--all]` | Show backup errors |

## Configuration

Config file: `~/.config/rusty-mac-backup/config.toml`

```toml
[source]
paths = [
    "~/.zshrc",
    "~/.gitconfig",
    "~/.ssh/config",
    "~/.config/ghostty",
    "~/.config/nvim",
    "~/GitHub",
]

[destination]
path = "/Volumes/BackupDisk/RustyMacBackup"

[exclude]
patterns = [
    "node_modules", ".git/objects", ".DS_Store",
    "Caches", "Cache", "*.tmp",
]

[retention]
hourly = 24
daily = 30
weekly = 52
monthly = 0
```

## Menu Bar App

Launch without arguments for the popover UI:

- Status icon with colored dot (green/yellow/red)
- **SwiftUI tree view** with collapsible categories and tri-state checkboxes per category/item
- Progress bar + speed + ETA during backup
- Add folders via file picker (with forbidden path enforcement)
- Eject disk, open backup folder, quit
- Auto-update banner when a new GitHub release is available

## Testing

```bash
./run-tests.sh
```

25 unit tests covering ExcludeFilter, Retention, Config parsing, BackupEngine, HardLinker, and legacy config migration.

## License

MIT
