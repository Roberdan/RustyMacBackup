# 🦀 RustyMacBackup

Fast, incremental backup tool for macOS using hard links. A Time Machine alternative that bypasses MDM restrictions.

## Why?

- **MDM-proof** — works at filesystem level, not through Apple's backup APIs
- **Fast** — compares files by size+mtime (no hashing), hard links unchanged files (zero I/O)
- **Space efficient** — unchanged files are hard-linked, only modified files use extra space
- **Browsable** — every backup is a normal folder, navigate it in Finder
- **Configurable** — TOML config, exclude patterns, retention policies
- **Scheduled** — built-in launchd integration for automatic backups

## Install

```bash
cargo install --path .
```

Or build manually:

```bash
cargo build --release
cp target/release/rustyback ~/.local/bin/
```

## Quick Start

```bash
# Create default config
rustyback init

# Edit config (source, destination, excludes)
rustyback config edit

# Run first backup
rustyback backup

# Enable hourly automatic backups
rustyback schedule on
```

## Commands

```
rustyback backup                           # Run backup now
rustyback list                             # List all backups
rustyback status                           # Show status + disk usage
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
rustyback schedule on                      # Enable hourly backup
rustyback schedule off                     # Disable schedule
rustyback schedule status                  # Show schedule status
rustyback schedule interval <minutes>      # Set custom interval
```

## How It Works

1. Walks the source directory, skipping excluded patterns
2. For each file, compares size + modification time with the latest backup
3. **Unchanged** → creates a hard link (instant, zero disk space)
4. **Changed/new** → copies the file
5. Backup is created atomically (`.in-progress` → renamed on completion)
6. Lock file prevents concurrent backups

## Retention Policy

Default retention keeps:
- **24** hourly backups (last 24 hours)
- **30** daily backups (last month)
- **52** weekly backups (last year)
- **Monthly** backups forever

## Default Excludes

Cloud-synced folders (OneDrive, iCloud, Dropbox), caches, build artifacts, `node_modules`, `.git/objects`, and more. See `rustyback config excludes` for the full list.

## Disk Full Protection

Before each backup, checks available disk space. If below 1 GB:
1. Auto-prunes old backups per retention policy
2. If still not enough space, aborts with a clear error

## License

MIT
