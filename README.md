# RustyMacBackup

> A native macOS menu-bar app that backs up your developer environment to an external disk — safely, incrementally, and without Full Disk Access.

Built for developers who live in the terminal and need a reliable, transparent backup of their configs, dotfiles, SSH keys, and project repos. Not a replacement for Time Machine — a complement to it.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green) ![Version](https://img.shields.io/badge/version-2.2.0-brightgreen)

---

## Why

Time Machine doesn't work on MDM-managed Macs. iCloud doesn't back up `~/.ssh` or `~/GitHub`. Cloud sync services fight with `node_modules` and `.git`. Git doesn't back up your shell config.

RustyMacBackup solves the problem that every developer has but nobody talks about: **your muscle memory lives in dotfiles, and they're never backed up.**

---

## How It Works

```
External Disk
└── RustyMacBackup/
    ├── 2026-03-20T14:32:00/    ← snapshot (hard-linked, incremental)
    │   ├── .zshrc
    │   ├── .gitconfig
    │   ├── .ssh/config
    │   ├── .config/nvim/
    │   └── GitHub/MyProject/
    ├── 2026-03-19T08:00:00/    ← yesterday (unchanged files = zero extra space)
    └── status.json             ← live progress / last result
```

Each backup creates a timestamped snapshot. **Unchanged files are hard-linked** from the previous snapshot — so 100 snapshots of a 2 GB config tree might use only 2.1 GB total. Changed files are copied with full attribute preservation (`copyfile()` with DATA|XATTR|STAT|ACL flags).

> ⚠️ **`COPYFILE_CLONE` is intentionally disabled.** On macOS, APFS cloning silently becomes a destructive *move* when source and destination are on different filesystems (APFS → ExFAT/HFS+). We've seen this destroy entire home directories. We use `copyfile()` with `COPYFILE_ALL = 0x0F` only.

Backups run:
- **On demand** — menu bar button or `rustyback backup`
- **On schedule** — via macOS `LaunchAgent` (hourly, daily, or custom interval)
- **Automatically stopped** on disk eject or low battery

---

## What Gets Backed Up

The app auto-discovers installed tools on first launch. You confirm what to include via a SwiftUI tree with collapsible categories and tri-state checkboxes.

| Category | Auto-discovered paths |
|----------|-----------------------|
| **Shell** | `.zshrc`, `.bashrc`, `.bash_profile`, `.config/fish/` |
| **Git** | `.gitconfig`, `.gitignore_global`, `.gitmessage` |
| **SSH** | `.ssh/config`, `.ssh/known_hosts` *(NOT private keys — by design)* |
| **Terminal** | Ghostty, Warp, iTerm2, Alacritty, kitty, tmux, zellij |
| **Editor** | Neovim, Vim, Emacs, VS Code, Cursor, Zed, Sublime Text |
| **Dev Tools** | starship, direnv, mise/asdf, Cargo config, Brewfile |
| **AI Tools** | Claude CLI settings, Ollama config |
| **Cloud/Auth** | Tailscale, 1Password CLI config |
| **macOS** | Dock prefs, Finder prefs, keyboard shortcuts |
| **Repos** | `~/GitHub`, `~/Developer`, `~/Projects` — or any custom path |
| **Custom** | Any file or folder you add via the `+` button |

### What It Will Never Touch

These paths are hardcoded as forbidden and enforced at both the UI and engine level:

```
~/Library/Mail         ~/Library/Messages      ~/Library/Safari
~/Library/Containers   ~/Library/CloudStorage  ~/Library/Caches
/Library   /System   /etc   /Applications   /usr   /opt   /private
```

No Full Disk Access required. No TCC prompts. No system file access.

---

## Installation

**From source (recommended for developers):**

```bash
git clone https://github.com/Roberdan/RustyMacBackup.git
cd RustyMacBackup
./install.sh        # builds with swiftc + installs to /Applications
```

Requires macOS 14+ (Sonoma) and Xcode Command Line Tools (`xcode-select --install`).

**From pkg installer:**

Download `RustyMacBackup-2.2.0-arm64.pkg` from [Releases](https://github.com/Roberdan/RustyMacBackup/releases) and double-click. No admin password needed after first install — auto-updates work in-place.

---

## Quick Start (CLI)

```bash
# Convenience alias
alias rustyback='/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup'

# First-time setup: discovers configs, picks destination disk
rustyback init

# See what configs are detected on this Mac
rustyback discover

# Run a backup now
rustyback backup

# Check live status + last result
rustyback status

# List snapshots
rustyback list
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `discover` | Show all detected dev tool configs |
| `init` | Interactive setup: discover + pick disk |
| `backup` | Run backup now (foreground, with progress) |
| `stop` | Cancel a running backup |
| `status` | Live status, last result, folder list |
| `list` | List snapshots on disk |
| `prune [--dry-run]` | Remove old snapshots per retention policy |
| `restore <snapshot> [path] --to <dest>` | Restore files from a snapshot |
| `config show\|add\|remove\|edit` | Manage backed-up paths |
| `schedule on\|off\|interval <min>\|daily <hour>` | Manage LaunchAgent schedule |
| `errors [--all]` | Show categorised backup errors |
| `--version` | Print version |

---

## Configuration

Config lives at `~/.config/rusty-mac-backup/config.toml` and is created by `rustyback init`. You can also edit it directly.

```toml
[source]
paths = [
    "~/.zshrc",
    "~/.gitconfig",
    "~/.ssh/config",          # known_hosts only — private keys excluded
    "~/.config/ghostty",
    "~/.config/nvim",
    "~/.config/starship.toml",
    "~/GitHub",               # entire GitHub folder, incremental
]

[destination]
path = "/Volumes/BackupDisk/RustyMacBackup"

[exclude]
patterns = [
    "node_modules", ".git/objects", "*.tmp",
    ".DS_Store", "Caches", "Cache", "__pycache__",
]

[retention]
hourly  = 24    # keep last 24 hourly snapshots
daily   = 30    # keep last 30 daily snapshots
weekly  = 52    # keep last 52 weekly snapshots
monthly = 0     # keep forever
```

---

## Menu Bar App

Launch the app (no arguments) to get the menu-bar popover:

```
┌─────────────────────────────────────┐
│ ● RustyMacBackup          [RUNNING] │
├─────────────────────────────────────┤
│ Backup in progress…                 │
│ SanDisk: 142 GB free                │
│ ████████████░░░░ 67%  8.2 MB/s      │
│ ETA: 2 min  ·  ~/GitHub/MyProject   │
├─────────────────────────────────────┤
│ [    Stop Backup    ]               │  ← red filled button
│ Ripristina snapshot…                │
│ Pianificazione: ogni ora            │
│ ─────────────────────────────────── │
│ Apri cartella backup                │
│ Espelli disco                       │
├─────────────────────────────────────┤
│ Esci                                │
└─────────────────────────────────────┘
```

**Status dot colours:**
- 🟢 Green — idle, last backup succeeded
- 🟡 Gold — backup running
- 🟠 Orange — stopping or backup overdue (>24 h)
- 🔵 Blue — restore in progress
- 🔴 Red — last backup failed / disk absent

**After a failed backup**, an error card appears with a localised description, suggested fix, and a direct "Show Log" link to Console.app.

---

## Architecture

Single-binary `.app` bundle — no frameworks, no SPM, no Xcode project. Compiled with raw `swiftc`.

```
Sources/
├── App/
│   ├── AppDelegate.swift       # NSApplicationDelegate, menu bar, popover lifecycle
│   ├── StatusManager.swift     # Polls status.json from disk, manages AppState
│   ├── AutoUpdater.swift       # GitHub release check, codesign verify, atomic install
│   ├── IconManager.swift       # Animated menu-bar icon (3-frame pulse per state)
│   └── main.swift              # Entry point: CLI dispatch or NSApplication.main()
├── Backup/
│   ├── BackupEngine.swift      # Core backup loop, lock, TaskGroup workers
│   ├── BackupEngine+Helpers.swift  # Mount validation, lock format, stale cleanup
│   ├── FileScanner.swift       # Recursive traversal with exclude filter
│   ├── HardLinker.swift        # Hard-link decision (mtime + size, 1 ms tolerance)
│   ├── RestoreEngine.swift     # Restore + manifest-based undo
│   ├── RetentionManager.swift  # Snapshot pruning (hourly/daily/weekly/monthly)
│   └── StatusWriter.swift      # Writes status.json + errors.json to disk
├── UI/
│   ├── PopoverView.swift       # SwiftUI popover (4-zone layout, 320 px)
│   ├── BackupTreeView.swift    # Collapsible tree with tri-state checkboxes
│   └── AppUIState.swift        # @Observable state shared between AppDelegate + SwiftUI
├── Config/
│   ├── Config.swift            # TOML config model + parser
│   ├── ConfigDiscovery.swift   # Auto-discovery of dev tool paths
│   └── ScheduleManager.swift  # LaunchAgent bootstrap/bootout
├── CLI/
│   └── CLIHandler.swift        # All CLI subcommands
└── Diagnostics/
    └── ErrorReporter.swift     # Error taxonomy, localised titles, suggested actions
```

**Key design decisions:**

- **No Full Disk Access** — whitelist model means we never need it
- **Hard links for deduplication** — same as Time Machine, but transparent
- **`copyfile()` not `COPYFILE_CLONE`** — APFS cloning is dangerous cross-volume (see above)
- **Lock file with PID + timestamp + UUID** — stale lock detection survives crashes
- **`mountedVolumeURLs()` not `statfs()`** — `statfs()` returns success on ejected volumes
- **`launchctl bootstrap/bootout`** — not the deprecated `load/unload`
- **No SPM / no Xcode** — single `swiftc` invocation, easy to audit, no dependency graph

---

## Building & Testing

```bash
# Build only
./build.sh

# Run unit tests (25 tests)
./run-tests.sh

# Build distributable .pkg + .app.zip
./build-pkg.sh

# Build specific version
VERSION=2.2.0 ./build-pkg.sh
```

Tests cover: `ExcludeFilter`, `RetentionManager`, `Config` parsing + round-trip, `BackupEngine` snapshot naming, `HardLinker` mtime logic, and legacy config migration.

---

## Restore & Undo

```bash
# List available snapshots
rustyback list

# Restore a specific file from a snapshot
rustyback restore 2026-03-20T14:32:00 .zshrc --to ~/.zshrc

# Restore everything from a snapshot
rustyback restore 2026-03-20T14:32:00 --to ~/
```

Before overwriting, the restore engine writes a `manifest.json` to a pre-restore backup dir (`~/.rustybackup-pre-restore/`). The **Undo Last Restore** button in the popover uses this manifest to restore exact paths — not a best-effort directory scan.

---

## Auto-Update

On launch, the app checks `https://github.com/Roberdan/RustyMacBackup/releases/latest` in the background. When a newer version is found:

1. A blue banner appears in the popover with an **Installa** button (and a **×** to dismiss)
2. Clicking install: downloads `.app.zip`, verifies codesign + bundle ID, extracts over the running app
3. Progress shown inline: *Scaricamento… → Verifica firma… → Installazione…*
4. On failure: the previous `.app` is restored from a rollback copy

FDA permissions are preserved because the update replaces the bundle in-place without reinstalling the LaunchAgent.

---

## Disclaimer

This software is provided **as-is**, without warranty of any kind. I built it for my own use and share it in the hope it's useful — but I take no responsibility for data loss, corruption, missed backups, or any other damage that may result from using it.

**Backup software is critical infrastructure.** Before relying on RustyMacBackup for anything important:
- Verify your backups actually restore correctly (`rustyback restore`)
- Keep at least one other backup method (Time Machine, cloud, etc.)
- Test on non-critical data first

The MIT licence applies — use at your own risk.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Read [`CLAUDE.md`](CLAUDE.md) first.

## License

MIT — see [LICENSE](LICENSE)

