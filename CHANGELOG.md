# Changelog

## [2.0.1] - 2026-03-20

### Fixed
- **BackupEngine crash (EXC_BAD_ACCESS)** -- replaced `UnsafeMutablePointer<Int64>` + `defer { deallocate() }` with a heap-allocated `Counters` class; ARC now guarantees pointer lifetime matches the `Task.detached` walker closure, eliminating the use-after-free race condition that caused crashes during actual backup runs.

## [2.0.0] - 2026-03-20

### SwiftUI UI Rewrite + Auto-Update

Complete UI rewrite from AppKit (flat NSStackView of 400+ items) to SwiftUI tree view. Added GitHub-based auto-update pipeline.

### Added
- **SwiftUI tree view** -- collapsible categories (Shell, Git, SSH, Terminal, Editor, AI Tools, Auth, Cloud, macOS, Repos) with tri-state checkboxes (checked / unchecked / mixed via native `NSButton` `allowsMixedState`)
- **AppUIState** -- shared `ObservableObject` bridging AppKit `AppDelegate` and SwiftUI views
- **Auto-updater** -- checks `api.github.com/repos/roberdan/RustyMacBackup/releases/latest` on launch, downloads `.app.zip`, installs in-place via `rsync` (preserves FDA permissions), relaunches
- **Update banner** -- blue banner in popover shows available version + spinner during download
- **GitHub Release workflow** -- `.github/workflows/release.yml` produces `.pkg` + `.app.zip` artifacts on tag push
- **`install.sh`** -- in-place installer: `rsync Contents/` preserves `.app` path so macOS TCC keeps FDA grant

### Changed
- `TreeWindowController` -- replaced ~365 lines of AppKit with thin `NSHostingController<TreeView>` wrapper
- `PopoverViewController` -- replaced ~310 lines of AppKit with thin `NSHostingController<PopoverView>` wrapper
- `AppDelegate` -- removed `PopoverDelegate`/`TreeWindowDelegate` conformances; uses closure callbacks + `AppUIState`
- `build.sh` -- `VERSION` from env var, stamps `Info.plist` in bundle, added `-framework SwiftUI`
- `build-pkg.sh` -- produces both `.pkg` AND `.app.zip`
- Version bumped to 2.0.0

### Removed
- `TreeWindowDelegate` and `PopoverDelegate` protocols -- replaced by closure callbacks



### Safe Whitelist-Only Rewrite

Complete safety overhaul: switched from dangerous blacklist model (backup everything, exclude bad stuff) to whitelist-only (backup ONLY chosen folders). The previous version caused system instability by scanning TCC-protected directories, triggering tccd crashes and bird mass-eviction cascades.

### Added
- **Whitelist-only backup model** -- `source.paths = [...]` replaces recursive home directory scanning
- **ConfigDiscovery** -- auto-detects installed dev tools (shells, editors, terminals, Git, SSH, AI tools, etc.)
- **Forbidden path enforcement** -- hardcoded blocklist of system/TCC-protected paths that can never be backed up
- **`discover` CLI command** -- shows all detected dev tool configs on your Mac
- **NSPopover UI** -- modern popover with vibrancy, replacing NSMenu-based UI
- **Add Folder via NSOpenPanel** -- file picker with forbidden path validation
- **Symlink skipping** -- FileScanner skips symbolic links to prevent loops and indirect TCC access
- **Single-file backup** -- can back up individual files (e.g. `~/.zshrc`) not just directories
- **Legacy config migration** -- old `source.path` + `extra_paths` format auto-migrates to `source.paths`
- **Config file permissions** -- saved with 0600 (owner-only read/write)
- **Restore path restriction** -- restore limited to home directory by default

### Removed
- **Full Disk Access requirement** -- no longer needed (whitelist model accesses only user-chosen paths)
- **FDACheck** -- removed TCC probing that could crash tccd
- **System path defaults** -- removed `/Applications`, `/opt/homebrew`, `/usr/local`, `/etc`, `/Library` from defaults
- **SpeedometerView** -- replaced by clean progress bar
- **MenuBuilder** -- replaced by PopoverViewController
- **Insecure auto-updater** -- removed (downloaded without signature verification)
- **Ferrari/Maranello Luce design** -- replaced by system-standard colors

### Fixed
- **System stability** -- no longer scans Library/Mail, Library/Messages, Library/Safari, Library/Containers, Library/CloudStorage, Library/Mobile Documents (TCC-protected paths)
- **iCloud daemon conflicts** -- no longer triggers bird mass-eviction by touching cloud-managed directories
- **StatusWriter race condition** -- atomic write replaces separate remove+move
- **ScheduleManager hardcoded path** -- now uses actual bundle executable path
- **CCC-aligned exclusions** -- added .Spotlight-V100, .fseventsd, DocumentRevisions-V100, .Trash, .TemporaryItems
- **App cache exclusions** -- added Caches, Cache, GPUCache, CachedData, CachedExtensions (VS Code/Cursor)

### Breaking Changes
- **Config format changed**: `source.path` + `extra_paths` replaced by `source.paths = [...]` (auto-migration supported)
- **No more Full Disk Access**: app no longer requests or needs FDA
- **CLI `config` subcommands**: `source`/`dest`/`exclude`/`include` replaced by `add`/`remove`
- **Version bumped to 2.0.0**

## [1.0.0] - 2026-03-19

### Full Swift Native Rewrite

Complete rewrite from Rust + Swift dual-binary to a single native Swift `.app` bundle.

### Added
- Single .app bundle serves as both menu bar app and CLI tool
- Backup engine with `copyfile()` APFS clone support and hard links
- Parallel file processing via Swift `TaskGroup` (8 workers)
- Manual TOML config parser (zero external dependencies)
- Battery-aware I/O throttling via `setiopolicy_np`
- Stale mountpoint detection via `statfs` device comparison
- 25 unit tests (ExcludeFilter, Retention, Config, BackupEngine, HardLinker)

## [0.3.1] - 2026-03-19

### Fixed
- Backup failures now diagnosed with actionable guidance
- Proactive disk diagnostics
- Eject disk visual feedback

## [0.3.0] - 2026-03-19

### Fixed
- Stale mountpoint detection
- Instant disk connect/disconnect detection

## [0.2.0] - 2026-03-18

### Added
- Auto-resume backup on disk reconnect
- Auto-updater checking GitHub releases

## [0.1.0] - 2026-03-17

### Added
- Initial release
