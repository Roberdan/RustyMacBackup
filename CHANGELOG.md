# Changelog

## [2.3.0] - 2026-08-25

### Added
- **Endpoint DLP guard** — on a Mac managed with Microsoft Purview, copying an *unlabeled*
  Office file to removable media is vetoed by the endpoint agent: `copyfile()` returns `EPERM`
  and macOS raises a modal justification dialog. During an unattended hourly backup nobody
  answers it and the file is never copied. `DLPGuard` now decides before the copy is attempted,
  so the dialog never appears. A file is skipped only when the destination is removable media,
  the file is an Office document, *and* it carries no MIP sensitivity label (read from
  `docProps/custom.xml` in the OOXML package).
- **`[dlp]` config section** — `skip_unlabeled_office` and `skip_when_label_unknown`, both
  defaulting to true. The TOML parser now understands booleans at all, which it previously did
  not.
- **`dlp_skipped` report category** — skipped files are counted in `status.json`
  (`files_skipped`) and named in `errors.json`, kept apart from real errors so a skip never
  inflates the error total. A file absent from the backup is always explainable.

### Fixed
- **Silent subtree loss in the scanner** — `FileScanner` called `enumerator.skipDescendants()`
  for every entry matching an exclude pattern, *files included*. `skipDescendants()` skips the
  subdirectory the enumerator is about to descend into, so an excluded file sitting immediately
  before a real directory swallowed that entire subtree. Nothing failed and nothing was logged:
  the files were simply absent from every snapshot. A single stray `.DS_Store` was enough — on
  this machine it cost `FDE_Update/zzArchive/` (6 files) and
  `the-standing-egg/docs/archive/exports/` (4 files), and any `*.log`, `*.tmp`, `*.pyc` or
  `*.jsonl` in the wrong position would do the same. `skipDescendants()` is now called only for
  directories.
- **Misleading advice on DLP failures** — these surfaced as `permission_denied`, whose
  suggested action is "check Full Disk Access". No local setting fixes a Purview policy, so
  the operator was sent chasing a fix that does not exist.
- **`files_skipped` never reported** — the field was written to `status.json` but never
  assigned, so it always read 0 while `errors.json` listed skipped files.
- **Stale recovery installer on the backup disk** — `install.sh` synced the `.app` and then
  copied "the newest `.pkg` lying around", which nothing ever rebuilt. The artifact whose
  entire purpose is restoring the app from the backup had sat at 1.0.0 since March while the
  installed app moved on: the one scenario it exists for would have handed back a five-month-old
  build. `install.sh` now builds the installer it ships (`build-pkg.sh`, which produces the app
  once and both artifacts from it), pins the copy to the version it just built rather than to a
  glob, and removes any older `.pkg` from the disk so there are never two with no way to tell
  which matches the `.app` beside them. `build-pkg.sh` also derives the version from `build.sh`
  instead of repeating the literal — the same drift, one level down.
- **Concurrency warnings in `AppDelegate`** — four `capture of 'self' with non-Sendable type`
  warnings. `AppDelegate` touches AppKit and `uiState` throughout, both main-thread-only, so the
  isolation was already real and simply undeclared; the class is now `@MainActor`. `runDiskutil`
  is explicitly `nonisolated`, since `handleEject` calls it from a background queue precisely
  because it blocks. Builds clean.

### Notes
- The DLP check runs **after** the hard-link attempt, not before. DLP vetoes the copy, not the
  link, so a file already present in the previous snapshot is still linked into the new one and
  stays in the backup chain. Enabling the guard never evicts what is already backed up.

## [2.2.0] - 2026-03-20

### Fixed
- **Lock file race condition** — lock format extended to `PID\nTIMESTAMP\nUUID`; stale cleanup only removes dirs older than 2 hours when no live owner is found (F-01)
- **Cancel safety** — cancelling a backup now deletes the in-progress snapshot instead of renaming it to a corrupt final snapshot (F-02)
- **Mount validation** — `statfs()` was returning success on stale `/Volumes/X` dirs even after disk ejection; now uses `mountedVolumeURLs()` to verify real mount (F-03)
- **Updater rollback** — auto-updater now verifies codesign + bundle ID before installing, rolls back automatically on rsync failure (F-04)
- **Undo restore** — restore now writes `manifest.json` with overwritten paths for precise undo; falls back to top-level scan for legacy dirs (F-05)
- **Traversal errors surfaced** — `FileScanner` now calls `onTraversalError` callback instead of silently swallowing directory read errors (F-08)
- **Status write errors** — critical status file writes no longer silently fail; errors are logged (F-09)
- **Free space preflight** — restore checks available disk space before starting (F-10)
- **LaunchAgent scheduler** — migrated from deprecated `launchctl load/unload` to `launchctl bootstrap/bootout` (F-11)
- **Version string** — CLI `--version` now reads from `Bundle` instead of a hardcoded "2.0.0" (F-12)
- **`~/` directory in repo** — accidental `~/` directory committed to repo root removed; added to `.gitignore` (F-13)
- **HardLinker mtime tolerance** — reduced from 1 second to 1 millisecond to avoid false cache hits on fast filesystems (F-07)
- **README false claim** — removed statement that COPYFILE_CLONE (APFS cloning) is used; it is explicitly forbidden as it performs a destructive move across volumes (F-23)

### Added
- **Transient UI states** — `.stopping` and `.restoring` app states prevent status flickering during stop/restore transitions (F-14)
- **Diagnostics error card** — when last backup failed, popover shows localised error title, suggested action, and "Show Log" / "Retry" buttons (F-15)
- **VoiceOver / Accessibility** — status dot, progress bar, badge, and all action buttons have `accessibilityLabel` / `accessibilityHint` (F-16)
- **Update banner dismiss** — × button lets user dismiss the update notification; banner shows download/verify/install phase text during update (F-17)
- **Post-restore result card** — shows restored/overwritten/failed counts for 60 seconds after a restore completes (F-18)
- **Cached backup state** — `hasBackups` and `canUndo` are cached in `AppUIState`; no disk I/O on each SwiftUI render cycle (F-19)
- **Phase-coloured progress bar** — scanning=grey, copying=gold, finalising=green, cancelled=red (F-21)
- **Animated menu-bar icon** — 3-frame pulse: gold=running, orange=stopping, blue=restoring (F-22)
- **Unified error taxonomy** — `ErrorReporter` provides `localizedTitle(for:)` and `suggestedAction(for:)` for all error categories (F-06)

### UI
- **Popover restructured** — 4 stable zones: Header / Health / Actions / Context; width 300 → 320 px (F-20)
- **Primary action button** — context-aware filled button: gold "Start Backup" at rest, red "Stop Backup" while running, inline label during stopping/restoring
- **Italian labels** — action buttons localised to Italian (Ripristina, Annulla, Espelli, Esci, Pianificazione)

## [2.1.0] - 2026-03-20

### Fixed
- **Snapshot path structure (CRITICAL)** -- `FileScanner` now uses the home directory as the base path for all sources. Previously each source path was used as its own base, causing all files to be stored flat in the snapshot root (e.g. `~/GitHub/MyRepo/file.swift` → `snapshot/file.swift`). Now stored as `snapshot/GitHub/MyRepo/file.swift`. This fix is required for cross-machine restore to work correctly.
- **Restore on different Mac** -- replaced `ConfigDiscovery.discover()` (filters by file existence) with new `ConfigDiscovery.candidatesForRestore(snapshotTopLevels:)` that matches against snapshot contents without requiring files to exist on the target machine.
- **Restore `~/` path bug** -- `confirmRestore()` now strips `~/` prefix before passing paths to `RestoreEngine` (was causing `snapshot/~/.gitconfig` lookups that always failed).
- **Restore UI categories** -- restore tree now shows the same categories as backup (Shell, Git, SSH, etc.) instead of flat "Dotfiles / Folders & Repos".
- **Repo restore** -- GitHub/Developer/Projects repos are scanned directly from snapshot subdirectories and shown individually in the "Repos" category.
- **Restore destination display** -- each restore item now shows destination path and `✚ nuovo` / `⚠ sovrascrive` badge.
- **Restore order** -- Homebrew packages are now installed *before* restoring config files (tools must exist before their config).
- **Restore progress** -- popover reopens automatically during restore to show live `[X/N] filename` progress bar.
- **StatusManager auto-create** -- if backup disk is mounted but the `RustyMacBackup/` folder was deleted, it is recreated automatically instead of showing NO DISK.
- **Stale lock detection** -- StatusManager verifies PID liveness with `kill(pid, 0)` to remove locks left by crashed processes.
- **"No backups yet"** -- synthesizes `lastCompleted` from snapshot folder names on disk when `status.json` is missing.
- **Tailscale** -- added to Cloud category in ConfigDiscovery (`~/Library/Preferences/io.tailscale.ipn.macos.plist` + `~/Library/Application Support/Tailscale`).

### Added
- **Add custom paths to backup** -- "＋ Aggiungi cartella o file…" button in backup tree opens NSOpenPanel; selected paths added to "Custom" category and saved to config.
- **Custom restore destination** -- each restore item has an ↗ button to redirect it to a different folder on the target machine (e.g. restore `~/Downloads` to `~/Documents/OldDownloads`).
- **Snapshot picker** -- when multiple snapshots exist, shows a picker with human-readable dates and "Ultimo" badge before opening the restore tree.
- **Schedule UI** -- "Schedule: Off/ogni 1h/…" button in popover wired to `launchd` via `ScheduleManager`; options: disable, hourly, every 6h, nightly at 00:00/02:00/03:00.
- **Parallel backup workers** -- `withThrowingTaskGroup` with 8 concurrent workers replaces sequential `for-await` loop (~2x throughput improvement).
- **Adaptive I/O throttle** -- `IOPOL_DEFAULT` on AC power, `IOPOL_THROTTLE` on battery; bird-safe pause 5ms on AC vs 100ms on battery.
- **`install.sh` syncs to backup disk** -- copies `.app` and latest `.pkg` to backup destination after every install.



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
