# Changelog

## [1.0.0] - 2026-03-19

### 🏎️ Full Swift Native Rewrite

Complete rewrite from Rust + Swift dual-binary to a single native Swift `.app` bundle.

### Added
- Single .app bundle serves as both menu bar app and CLI tool
- Backup engine with `copyfile()` APFS clone support and hard links
- Parallel file processing via Swift `TaskGroup` (8 workers)
- Manual TOML config parser (zero external dependencies)
- Battery-aware I/O throttling via `setiopolicy_np`
- Stale mountpoint detection via `statfs` device comparison
- Full Disk Access diagnostics with actionable Italian messages
- Maranello Luce design system (Ferrari-inspired adaptive colors)
- ProgressBarView — gradient progress bar (rosso→gold→verde)
- SpeedometerView — animated Ferrari-style gauge with spring physics
- Status bar icon with colored dot and micro-animations
- Schedule/preferences submenus in menu bar
- UNUserNotification alerts for backup events
- GitHub release auto-updater
- 25 unit tests (ExcludeFilter, Retention, Config, BackupEngine, HardLinker)
- `build.sh` and `build-pkg.sh` for .app and .pkg distribution

### Breaking Changes
- **Rust binary removed** — `rustyback` CLI is gone
- **Single .app replaces two binaries** — no more `RustyBackMenu.app` + `rustyback`
- **CLI access**: `/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup <command>`
- **LaunchAgent updated**: ProgramArguments now points to .app bundle binary
- **macOS 14+ required** (was 13+)

## [0.3.1] - 2026-03-19

### Fixed
- **Backup failures now diagnosed with actionable guidance**: "Operation not permitted" errors show exactly how to fix (Full Disk Access, disk permissions, or Finder instructions) — both in CLI and in the menu bar
- **Menu bar shows error state clearly**: red "ERRORE" header + specific fix instructions instead of misleading stale data ("0 secondi · 2 file · 2 bytes")
- **Proactive disk diagnostics**: write test runs automatically when disk connects, warns in menu if disk is not writable with step-by-step fix
- **Full Disk Access detection actually works**: `checkFullDiskAccess()` now probes TCC-protected dirs (was always returning true — FDA warning screen never showed)
- **Eject disk gives immediate visual feedback**: icon pulses during eject, menu shows "Espulsione in corso...", success/failure notification with details
- **All user actions give visual feedback**: brief blue icon flash confirms schedule, retention, and exclude pattern changes
- **Stop backup responds immediately**: icon and menu update instantly instead of waiting for next poll
- `write_error_status()` no longer preserves stale file counts from previous runs

## [0.3.0] - 2026-03-19

### Fixed
- Disk detection now uses `mountedVolumeURLs` (Swift) and `statfs` device comparison (Rust) to avoid stale mountpoints that macOS leaves in `/Volumes/` after unmount
- Backups no longer start against stale mountpoints, preventing ghost files written to the root filesystem
- Instant disk connect/disconnect detection via `NSWorkspace.didMountNotification` / `didUnmountNotification` instead of waiting for 30s polling cycle

### Added
- **Eject Disk button** (Cmd+E): safely stops any running backup and ejects the backup disk — essential for MacBook users
- Colored status bar icon: green (healthy), red (disk absent), orange (error), gold (stale backup)
- Animated backup icon using `externaldrive.badge.timemachine` in gold during backup
- Color-coded menu header: green when disk connected, red when absent, gold during backup
- Hint text "Collega il disco per avviare il backup" when disk is absent
- Prominent disk info with green dot and colored volume name in idle view
- New colorful app icon: blue background, white hard drive, green shield with checkmark, gold sync arrows
- Icon generator script (`menubar/generate-icon.sh`)

### Changed
- Status bar icons use palette colors instead of monochrome template mode
- "Backup in corso" button renamed to "Ferma backup" for clarity
- "Backup Now — disco assente" uses colored text instead of small muted text

## [0.2.0] - 2026-03-18

### Added
- Auto-resume backup on disk reconnect
- App icon and menu bar SF Symbol icons
- Auto-updater checking GitHub releases
- Robust CI pipeline

### Fixed
- Recover interrupted backups instead of deleting them
- Backup files now visible in Finder (removed dot-prefix)
- Critical bugs from independent audit

## [0.1.0] - 2026-03-17

### Added
- Initial release
- Fast incremental backups with hard-link deduplication
- Native macOS menu bar app (Cocoa/AppKit)
- TOML-based configuration
- Launchd scheduling
- Retention policy (hourly/daily/weekly/monthly)
- Parallel file processing with rayon
- Adaptive I/O priority (throttle on battery)
- Encryption detection for backup volumes
