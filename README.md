# 🏎️ RustyMacBackup

Fast, native macOS backup tool with a Ferrari-inspired menu bar app. A Time Machine alternative that bypasses MDM restrictions.

**Single native `.app` bundle** — pure Swift, zero dependencies, one Full Disk Access entry.

## Features

- **Native macOS app** — single .app serves as menu bar app AND CLI tool
- **Incremental backups** with hard links (unchanged files = zero space)
- **APFS clone support** — instant file copies via `copyfile()` with `COPYFILE_CLONE`
- **Parallel I/O** — 8 concurrent workers via Swift `TaskGroup`
- **Smart excludes** — glob patterns skip caches, cloud storage, build artifacts
- **Battery-aware** — throttles I/O on battery, full speed on AC
- **Maranello Luce UI** — Ferrari-inspired design with animated speedometer gauge
- **Disk safety** — stale mountpoint detection, disconnect-proof, lock files
- **Scheduled backups** — via macOS LaunchAgent (every N minutes or daily)
- **Full Disk Access diagnostics** — probes TCC paths, shows actionable fixes

## Installation

### From .pkg installer
```bash
# Download latest .pkg from Releases
sudo installer -pkg RustyMacBackup-1.0.0.pkg -target /
```

### Build from source
```bash
git clone https://github.com/Roberdan/RustyMacBackup.git
cd RustyMacBackup
./build.sh
# Copy to Applications
cp -r build/RustyMacBackup.app /Applications/
```

**Requirements**: macOS 14+ (Sonoma), Xcode Command Line Tools (`xcode-select --install`)

## Quick Start

```bash
# Set up an alias for convenience
alias rustyback='/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup'

# First-time setup
rustyback init

# Run a backup
rustyback backup

# Check status
rustyback status

# List snapshots
rustyback list
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `backup` | Run backup now |
| `stop` | Stop running backup |
| `list` | List backup snapshots |
| `status` | Show backup status |
| `prune [--dry-run]` | Clean up old backups |
| `restore <snapshot> [path] --to <dest>` | Restore from backup |
| `init` | First-time setup wizard |
| `config show\|source\|dest\|exclude\|include\|excludes\|retention\|edit` | Manage config |
| `schedule on\|off\|status\|interval <min>\|daily <hour>` | Manage schedule |
| `errors [--all]` | Show backup errors |
| `version` | Show version |

Global option: `-c <path>` to use a custom config file.

## Menu Bar App

Launch RustyMacBackup.app without arguments to start the menu bar app:

- **Status icon** with colored dot (green=healthy, yellow=stale, red=error, blue=running)
- **Live progress** with gradient progress bar and speedometer gauge
- **Schedule management** submenu
- **Preferences** submenu (exclude patterns, retention policy)
- **Disk management** — eject, encryption check, space monitoring
- **Notifications** — backup complete/failed, disk events

## How It Works

1. **Scan** source directories (skip excluded paths, don't descend into them)
2. **Compare** each file with the latest backup (size + modification time)
3. **Hard-link** unchanged files (zero disk space, instant)
4. **Copy** changed files via `copyfile()` with APFS clone support
5. **Atomic rename** from `in-progress-*` to final timestamp on success

## Configuration

Config file: `~/.config/rusty-mac-backup/config.toml`

```toml
[source]
path = "/Users/username"
extra_paths = ["/Applications", "/opt/homebrew", "/usr/local", "/etc", "/Library"]

[destination]
path = "/Volumes/BackupDisk/RustyMacBackup"

[exclude]
patterns = [
    ".Spotlight-*", ".fseventsd", ".DS_Store", "Library/Caches",
    "node_modules", ".git/objects", "target/debug", "*.tmp",
]

[retention]
hourly = 24
daily = 30
weekly = 52
monthly = 0    # 0 = keep one per month forever
```

## Retention Policy

| Period | Default | Meaning |
|--------|---------|---------|
| Hourly | 24 | Keep 24 most recent hourly backups |
| Daily | 30 | Keep 30 daily (one per day) |
| Weekly | 52 | Keep 52 weekly (one per week) |
| Monthly | 0 | Keep one per month forever |

## Testing

```bash
./run-tests.sh
```

Runs 25 unit tests covering ExcludeFilter, Retention, Config parsing, BackupEngine, and HardLinker.

## License

MIT © Roberdan 2026
