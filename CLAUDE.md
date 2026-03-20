# CLAUDE.md — RustyMacBackup

## Project

Native macOS backup app (Swift, AppKit/SwiftUI). Single `.app` binary that acts as both menu bar app and CLI tool. No external dependencies. Target: macOS 14+ arm64.

**Product**: whitelist-only incremental backup with hard links. Time Machine alternative for MDM-restricted Macs. Dev-tool configs + arbitrary folders.

## Build & Test

```bash
./build.sh              # compile + sign → build/RustyMacBackup.app
./run-tests.sh          # 25 unit tests → build/RustyMacBackupTests
./build-pkg.sh          # creates .pkg installer
```

Version must be set consistently — currently **inconsistent** (P2):
- `build.sh` defaults `VERSION=2.1.0`
- `build-pkg.sh` defaults `VERSION=2.0.0`
- `Sources/CLI/CLIHandler.swift:5` hardcodes `"2.0.0"`

Always update all three together.

## Module Map

```
Sources/
  App/          AppDelegate, main, StatusManager, AutoUpdater, IconManager, MenuBuilder
  Backup/       BackupEngine(+Helpers), HardLinker, FileScanner, RestoreEngine,
                RetentionManager, ExcludeFilter, EnvironmentSnapshot, StatusModels, BackupTypes
  Config/       ConfigManager, ConfigDiscovery, ScheduleManager
  CLI/          CLIHandler
  Diagnostics/  Log, ErrorReporter, DiskDiagnostics, FDACheck
  UI/           PopoverView, TreeView, AppUIState, SpeedometerView, ProgressBarView,
                SnapshotPickerView, DesignTokens, TreeWindowController, PopoverViewController
```

## ⚠️ CRITICAL KNOWN TRAP — COPYFILE_CLONE DESTROYS SOURCE FILES

**Do NOT use `COPYFILE_CLONE` flag with `copyfile()` across different filesystems.**

When copying APFS → ExFAT/HFS+ (or any cross-volume operation), `COPYFILE_CLONE` silently degrades to a **move** — it deletes the source file. This has destroyed the developer's Mac multiple times.

**Current safe implementation** (`HardLinker.swift:26`):
```swift
// COPYFILE_ALL = DATA|XATTR|STAT|ACL = 0x0F  (NO CLONE!)
let flags = copyfile_flags_t(UInt32(0x0F))
```

**Never change this to use `COPYFILE_CLONE` (1<<24) or any clone flag.** Even if Apple docs suggest it for performance, it is unsafe for cross-volume operations. The README erroneously still mentions "APFS clone support" — that line is wrong, the feature was removed for safety.

## Architecture Decisions

- **Single binary**: CLI mode detected via `ProcessInfo.processInfo.arguments`. If args present → CLI, otherwise → menu bar app.
- **Hard links for deduplication**: `HardLinker.shouldHardLink()` checks size + mtime delta < 1.0s. Files identical to previous snapshot get hard-linked (zero space cost).
- **Snapshot naming**: `in-progress-YYYY-MM-DD_HHmmss` during backup, renamed to `YYYY-MM-DD_HHmmss` on success.
- **8 parallel workers**: `TaskGroup` bounded to 8 concurrent `processFile` tasks.
- **Status file**: `~/.local/share/rusty-mac-backup/status.json` — updated every 500 files.
- **Config**: `~/.config/rusty-mac-backup/config.toml`
- **Lock file**: `<destination>/rustymacbackup.lock` (PID-based, stale detection via `kill(pid, 0)`).

## Known Critical Issues (from 2026-03-20 audit)

### P0 — Must fix before wide distribution

| ID | Location | Issue |
|----|----------|-------|
| P0.1 | `BackupEngine.swift:44-45` | `cleanStaleInProgress()` runs **before** lock acquisition — concurrent run can delete active in-progress dir |
| P0.2 | `BackupEngine.swift:191` | Cancelled backup still renames `in-progress-*` to final snapshot — partial backup looks valid |
| P0.3 | `BackupEngine+Helpers.swift:8-11` | Mount validation uses only `statfs()` — stale `/Volumes` mountpoint can redirect backup to internal disk |
| P0.4 | `AutoUpdater.swift:51-89` | Updater does `rsync --delete` with no signature verification and no rollback |
| P0.5 | `RestoreEngine.swift:118-123,173-210` | Undo restore replaces entire top-level dirs, not individual files — can destroy newer files |
| P0.6 | `BackupEngine+Helpers.swift:67-80` | Error categories use Swift type names as keys; `ErrorReporter` expects semantic keys (`permission_denied` etc.) |

### P1 — High priority

- `HardLinker.swift:13`: mtime tolerance 1.0s can miss same-size edits — reduce significantly
- `FileScanner.swift:61-66`: traversal errors swallowed (errorHandler always returns `true`)
- Multiple `try? statusWriter.write(...)` silently drop persistence failures
- `RestoreEngine.swift`: restore has no free-space preflight
- `ScheduleManager.swift:57-74`: uses legacy `launchctl load/unload` — migrate to `bootstrap/bootout gui/<uid>`

## Forbidden Paths (hardcoded)

Never allow backup of: `Library/Mail`, `Library/Messages`, `Library/Safari`, `Library/Containers`, `Library/CloudStorage`, `Library/Mobile Documents`, `Library/Caches`, `/Library`, `/System`, `/etc`, `/Applications`, `/usr`, `/opt`, `/private`

## UI State

- `AppUIState.hasBackups` calls `RestoreEngine.findBackupSnapshots()` as a computed property — **disk I/O in view layer**. Do not make it worse; cache this.
- Stop button sets UI to idle before engine fully drains — expected, tracked as P2.

## Testing

Tests live in `tests/`. Run via `./run-tests.sh`. No SPM/Xcode project — raw `swiftc` compilation.
Covers: ExcludeFilter, Retention, Config parsing, BackupEngine, HardLinker, legacy config migration.
