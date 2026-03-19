# Changelog

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
