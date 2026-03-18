# RustyMacBackup

Fast, incremental backup tool for macOS with a native menu bar app. A Time Machine alternative that bypasses MDM restrictions.

## Why?

- **MDM-proof** — works at filesystem level, not through Apple's backup APIs
- **Fast** — parallel file processing with rayon, adaptive I/O priority
- **Space efficient** — unchanged files are hard-linked (zero extra space)
- **Browsable** — every backup is a normal folder, navigate it in Finder
- **Native menu bar app** — real-time progress, Ferrari-inspired speedometer, Maranello Luce Design styling
- **Safe** — detects disk disconnection mid-backup, battery guard, smart lock recovery
- **Configurable** — TOML config, exclude patterns, retention policies, schedule

## Screenshots

The menu bar app shows real-time backup progress with a gradient progress bar, a mini speedometer gauge, and Maranello Luce Design color system (gold/verde/rosso).

## Install

On a new Mac:

```bash
git clone https://github.com/Roberdan/RustyMacBackup.git
cd RustyMacBackup
bash install.sh
```

This will:
1. Build the Rust backup engine (`rustyback` CLI)
2. Install to `~/.local/bin/`
3. Build the native menu bar app → `/Applications/RustyBackMenu.app`
4. Run the interactive setup wizard (disk selection, config)

**Requirements:** Rust toolchain (auto-installed if missing), Xcode Command Line Tools.

After install, grant **Full Disk Access** in System Settings → Privacy & Security to:
- Your terminal app
- `/Applications/RustyBackMenu.app`

### Manual install

```bash
cargo build --release
cp target/release/rustyback ~/.local/bin/
bash menubar/build.sh
rustyback init
```

## Quick Start

```bash
# Interactive setup wizard (disk selection, permissions, first backup)
rustyback init

# Or manual config
rustyback config edit

# Run first backup
rustyback backup

# Enable automatic backups
rustyback schedule on
```

## Menu Bar App

The native macOS menu bar app (`RustyBackMenu.app`) provides:

- **Real-time progress** — gradient progress bar (rosso → gold → verde) with percentage
- **Speed gauge** — Ferrari-style mini speedometer showing MB/s with needle and arc
- **Smart status** — disk connected/absent detection, last backup time, ETA
- **Full configuration** — disk selector, source paths, exclude patterns, retention, schedule
- **Disk safety** — disables backup actions when disk is not connected
- **Maranello Luce Design** — color system from the Ferrari-inspired design system

Build and install:
```bash
bash menubar/build.sh              # Build + install to /Applications
bash menubar/build.sh --login-item # Also add as login item
```

## CLI Commands

```
rustyback init                             # Interactive setup wizard
rustyback backup                           # Run backup now
rustyback stop                             # Stop running backup
rustyback list                             # List all backups
rustyback status                           # Show status + disk usage
rustyback errors [--all]                   # Show errors from last backup
rustyback prune [--dry-run]                # Remove old backups per retention policy
rustyback restore <name> [path] [--to dir] # Restore backup or single file
rustyback config show                      # Show current config
rustyback config source <path>             # Set backup source
rustyback config dest <path>               # Set backup destination
rustyback config exclude <pattern>         # Add exclude pattern
rustyback config include <pattern>         # Remove exclude pattern
rustyback config excludes                  # List all excludes
rustyback config retention --hourly 24     # Set retention policy
rustyback config edit                      # Open config in $EDITOR
rustyback schedule on                      # Enable scheduled backup
rustyback schedule off                     # Disable schedule
rustyback schedule status                  # Show schedule status
rustyback schedule interval <minutes>      # Set custom interval (15/30/60/120)
rustyback schedule daily <hour>            # Daily backup at specific hour
```

## How It Works

1. Walks source directories in parallel, skipping excluded patterns via `filter_entry()`
2. For each file, compares size + mtime with the latest backup
3. **Unchanged** → hard link (instant, zero disk space)
4. **Changed/new** → buffered copy (256KB I/O buffer)
5. Backup created atomically (`.in-progress-*` → renamed on completion)
6. Lock file prevents concurrent backups, auto-recovers stale locks
7. Status file (`status.json`) updated every 500 files for real-time monitoring
8. Errors saved to `errors.json` with categorization (permission/not-found/IO/other)

## Features

- **Parallel processing** — rayon thread pool for file operations
- **Adaptive I/O** — full speed on AC power, throttled on battery
- **Disk disconnect detection** — checks every 100 files, graceful stop via AtomicBool
- **Battery guard** — skips scheduled backups when on battery
- **Multi-source** — home directory + /Applications + /opt/homebrew + /etc + /Library
- **Smart excludes** — cloud storage, caches, build artifacts, node_modules, .git/objects
- **Disk full protection** — auto-prunes before backup if <1GB free

## Retention Policy

Default retention:
- **24** hourly backups
- **30** daily backups
- **52** weekly backups
- **Monthly** backups forever

## Requirements

- macOS 13+ (Ventura or later)
- Rust toolchain (for building)
- External disk (APFS recommended)
- Full Disk Access (System Settings → Privacy → Full Disk Access)

## License

MIT — © Roberdan 2026
