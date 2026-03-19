# RustyMacBackup v1.0 — Native macOS Backup App

## Vision

Build the **sexiest backup app on macOS**. A single native `.app` that makes Time Machine look dated. Think Apple design language but with more personality — an Italian racing-inspired "Maranello Luce" design system with Ferrari gold accents, racing green health indicators, and a speedometer gauge that makes watching a backup actually fun.

Zero Electron. Zero web views. Zero external binaries. Pure Swift, pure AppKit, pure macOS. The kind of app that makes people say "wait, THIS is a backup tool?"

**Target**: macOS 14+ (Sonoma), Swift 5.9+, AppKit for menu bar, SwiftUI for any future settings window.

## Architecture: Single .app Bundle

```
RustyMacBackup.app/
  Contents/
    MacOS/RustyMacBackup     ← single binary does everything
    Resources/               ← icons, assets
    Info.plist
```

ONE app. ONE Full Disk Access entry. ONE LaunchAgent. No external binaries, no ~/.local/bin, no separate CLI tool.

The app has two operating modes:
1. **Menu bar mode** (default): runs as `LSUIElement` menu bar app with status icon
2. **CLI mode**: when launched from terminal with arguments (e.g. `RustyMacBackup.app/Contents/MacOS/RustyMacBackup backup`), acts as CLI tool — print to stdout, exit when done. Detect via `ProcessInfo.processInfo.arguments`.

## Core Features (ALL must be implemented)

### 1. Backup Engine

**Incremental backup with hard links** (like rsync --link-dest):

- Walk source directories, skip excluded paths (don't descend into excluded dirs)
- For each file: compare size + mtime with same file in latest backup
  - **Unchanged** → hard link to previous backup (instant, zero space)
  - **Changed/new** → copy using `copyfile()` with `COPYFILE_CLONE` flag (APFS clone when possible, automatic fallback to byte copy)
- Preserve modification times on copied files
- Create timestamped snapshot directories: `YYYY-MM-DD_HHMMSS`
- During backup, use `in-progress-YYYY-MM-DD_HHMMSS` prefix, rename to final on completion
- **Parallel file processing** using Swift `TaskGroup` for I/O throughput
- Lock file to prevent concurrent backups (`rustyback.lock` with PID, check if stale)
- Detect disk disconnection mid-backup (check if `in-progress` dir still exists every 100 files)
- Write progress to `~/.local/share/rusty-mac-backup/status.json` every 500 files

**I/O optimization:**
- Use `copyfile()` (Apple's optimized copy with APFS clone support) instead of manual buffered copy
- Set I/O priority: `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE)` on battery, `IOPOL_DEFAULT` when plugged in
- Detect battery via `IOPSCopyPowerSourcesInfo()`
- Check minimum 1GB free space before starting, auto-prune if needed

### 2. Configuration (TOML format)

Config file: `~/.config/rusty-mac-backup/config.toml`

```toml
[source]
path = "/Users/username"
extra_paths = [
    "/Applications",
    "/opt/homebrew",
    "/usr/local",
    "/etc",
    "/Library",
]

[destination]
path = "/Volumes/DiskName/RustyMacBackup"

[exclude]
patterns = [
    ".Spotlight-*", ".fseventsd", ".Trash", ".Trashes", ".DS_Store",
    ".TemporaryItems", ".VolumeIcon.icns",
    "Library/Caches", "Library/Logs", "Library/Application Support/Caches",
    "Library/Saved Application State", "Library/Containers/*/Data/Library/Caches",
    "Library/Updates", "Library/Developer",
    "OneDrive*", "Library/CloudStorage", "Library/Mobile Documents",
    "Library/Group Containers/*.Office", "Dropbox", "Google Drive", "iCloud Drive*",
    "node_modules", ".git/objects", "target/debug", "target/release", ".build",
    "*.tmp", "*.swp", ".cache", "__pycache__", ".venv", ".tox",
    ".ollama/models", ".lmstudio", "*.iso", "*.dmg",
]

[retention]
hourly = 24
daily = 30
weekly = 52
monthly = 0
```

Parse TOML manually (it's simple key-value, no need for a library). Glob matching for exclude patterns supporting `*` and `?` wildcards.

### 3. Retention & Pruning

Keep backups according to policy:
- Keep N most recent hourly backups
- Keep N daily (one per day, most recent per day)
- Keep N weekly (one per week)
- Keep N monthly (0 = keep forever)

Prune = delete snapshot directories that don't fit any retention slot.

### 4. Status File

`~/.local/share/rusty-mac-backup/status.json`:
```json
{
  "state": "idle|running|error",
  "started_at": "ISO8601",
  "last_completed": "ISO8601",
  "last_duration_secs": 45.2,
  "files_total": 150000,
  "files_done": 75000,
  "bytes_copied": 1073741824,
  "bytes_per_sec": 52428800,
  "eta_secs": 30,
  "errors": 5,
  "current_file": "Documents/report.pdf"
}
```

Error details in `~/.local/share/rusty-mac-backup/errors.json`:
```json
{
  "total": 5,
  "timestamp": "ISO8601",
  "categories": {
    "permission_denied": { "count": 3, "files": ["Library/Mail/..."] },
    "not_found": { "count": 2, "files": ["..."] },
    "io_error": { "count": 0, "files": [] },
    "other": { "count": 0, "files": [] }
  }
}
```

### 5. LaunchAgent (Scheduled Backups)

Generate and manage `~/Library/LaunchAgents/com.roberdan.rusty-mac-backup.plist`.

The ProgramArguments must point to the binary INSIDE the .app bundle:
```xml
<key>ProgramArguments</key>
<array>
    <string>/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup</string>
    <string>backup</string>
</array>
```

Support: interval (every N minutes), daily at hour, on/off, status check.

### 6. First-Time Setup Wizard (init)

Interactive flow:
1. Check Full Disk Access (probe `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`)
2. Discover external volumes (skip "Macintosh HD")
3. Check disk encryption (require it, show instructions if not)
4. Create backup directory on selected disk
5. Generate config.toml
6. Offer to run first backup

### 7. Restore

Restore a specific file/folder from any backup snapshot to original location or custom path.

## Menu Bar UI (AppKit — NOT SwiftUI for the menu)

Use `NSStatusItem` + `NSMenu` with `NSAttributedString` for colored text. The menu bar must be AppKit because SwiftUI MenuBarExtra has limited customization.

### Design System: "Maranello Luce"

Italian-flavored color palette (adaptive light/dark):

| Token | Dark Mode | Light Mode |
|-------|-----------|------------|
| gold | #FFC72C | #8B6B00 |
| rosso | #DC0000 | #AA0000 |
| verde | #00A651 | #007A3D |
| info | #448AFF | #005ACC |
| warning | #FFB300 | #996600 |
| grigio | secondaryLabelColor | secondaryLabelColor |
| dimmed | tertiaryLabelColor | tertiaryLabelColor |

### Menu States

**Idle (disk connected, backup OK):**
```
● RustyMacBackup                      (verde)
──────────────────
● Ultimo backup: 2 ore fa             (verde/gold/rosso based on age)
  45 secondi · 150.000 file · 12 GB
● RoberdanBCK  1,93 TB liberi         (verde)
  Prossimo: tra 25 min                (gold)
  5 file di sistema ignorati (normale)
──────────────────
● Backup Now                    ⌘B    (verde)
  Open Backup Folder            ⌘O
  Espelli disco                 ⌘E    (info/blue)
──────────────────
  Schedule: Every 60 min        >     (submenu)
──────────────────
  Preferences                   >     (submenu)
──────────────────
  View Backup Log
  Quit                          ⌘Q
```

**Running:**
```
● RustyMacBackup  BACKUP IN CORSO     (gold + verde)
──────────────────
  [████████████░░░░░░░░] 60%          (gradient progress bar)
  5.2 GB copiati  75.000 / 150.000 file
  [speedometer gauge]                  (Ferrari-style)
  Speed: 52 MB/s  ETA: 30s
  ▸ Documents/report.pdf               (current file)
──────────────────
● Ferma backup                  ⌘B    (gold)
```

**Error (disk connected but backup failed):**
```
● RustyMacBackup  ERRORE              (rosso)
──────────────────
● Backup fallito                       (rosso)
  ⚠ Serve Full Disk Access            (rosso)
  Apri Impostazioni Privacy...         (clickable)
● Ultimo OK: 2 giorni fa              (rosso)
● RoberdanBCK  1,93 TB liberi
  Premi Backup Now per riprovare
```

**Disk absent:**
```
● RustyMacBackup                      (rosso)
──────────────────
● Disco "RoberdanBCK" non collegato   (rosso)
  Collega il disco per avviare il backup
```

**FDA missing:**
```
  RustyMacBackup
──────────────────
● Full Disk Access richiesto           (rosso)
  Senza FDA il backup non può accedere ai tuoi file
──────────────────
  Apri Impostazioni Privacy...         (clickable)
  Aggiungi RustyMacBackup.app a FDA
```

### Custom Views in Menu

1. **ProgressBarView**: gradient bar rosso→gold→verde with smooth animation, rounded ends, subtle glow on the filled portion. 250x32px. Shows percentage number centered on the bar in contrasting text.
2. **SpeedometerView**: Ferrari-inspired gauge — arc from red (slow) through gold to green (fast), with a needle that animates smoothly. Shows current MB/s as large number, ETA below in small text. 220x90px. The gauge should feel alive — needle bounces slightly on speed changes.

### Micro-Animations & Polish

The app should feel ALIVE, not static:

- **Backup progress**: the menu bar icon dot pulses between blue and cyan (0.8s interval), giving a "heartbeat" feel
- **Eject disk**: icon animates during eject, menu shows "Espulsione in corso..." with a subtle pulsing gold dot
- **Completion**: when backup finishes, the dot briefly flashes verde bright then settles to normal verde (celebration flash)
- **Error**: dot pulses rosso twice then stays solid (attention pulse)
- **Preference changes**: brief blue dot flash (0.6s) confirming action was received
- **Speed gauge needle**: smooth spring animation when speed changes, not instant jumps
- **Progress bar**: smooth fill animation, not choppy per-file jumps (interpolate between status updates)

### Notification Style

Notifications should feel premium:
- Backup complete: "✅ Backup completato — 45s · 150.000 file · 12 GB"
- Backup failed: "❌ Backup fallito — [specific actionable reason]"
- Disk ejected: "✅ Disco espulso — RoberdanBCK rimosso in sicurezza"  
- Disk reconnected: "💾 Disco ricollegato — backup automatico tra 3s..."

### Status Bar Icon

- Use SF Symbol `externaldrive.badge.timemachine`
- Compose template icon + small colored dot (like Teams online status):
  - 🟢 Green: healthy, recent backup
  - 🟡 Yellow: stale (>24h since last backup)
  - 🟠 Orange: errors
  - 🔴 Red: disk not connected
  - 🔵 Blue/Cyan animated: backup running (alternate between two colors every 0.8s)

### Proactive Diagnostics

The app MUST actively diagnose problems and show solutions in the menu:

1. **On disk connect**: write a probe file to test writability. If EPERM → show "Finder → Get Info → Ignore Ownership" in menu
2. **On backup failure**: read error log, detect FDA/permission/space issues, show targeted fix
3. **FDA check**: probe TCC-protected dirs on launch, warn if not readable
4. **Disk space**: color-code free space (verde >50GB, warning <50GB, rosso <10GB)

### User Action Feedback

EVERY user-initiated action must give immediate visual feedback:
- **Eject disk**: icon starts pulsing, menu shows "Espulsione in corso..." (gold), success/failure notification
- **Schedule/preference changes**: brief blue dot flash on icon (0.6s)
- **Stop backup**: immediately stop animation, restore idle icon
- **Backup Now**: immediately start animation, switch to running menu

### Volume Management

- Detect mount/unmount via `NSWorkspace.didMountNotification` / `didUnmountNotification`
- Auto-resume backup when disk reconnects if last backup was error/stale
- Use `FileManager.mountedVolumeURLs` to detect real mounts vs stale mountpoints
- Check volume encryption via `diskutil info`

### Preferences Submenu

- Backup destination (select from mounted volumes)
- Source paths (add/remove extra paths)
- Exclude patterns (add/remove, toggle common ones)
- Retention policy (hourly/daily/weekly/monthly counts)

### Schedule Submenu

- Every 15/30/60/120/360 min
- Daily at specific hour (0-23)
- Off
- Show current status

### Notifications (UNUserNotification)

- Backup complete (duration + file count)
- Backup failed (brief error)
- Disk reconnected + auto-resume
- Disk ejected successfully
- Disk eject failed (with error detail)

### Auto-Updater

Check GitHub releases on launch (after 5s delay). Compare bundle version vs latest release tag. Show "Aggiornamento vX.Y.Z" in menu if available.

## File Structure

```
RustyMacBackup/
  Package.swift              (or Xcode project)
  Sources/
    App/
      main.swift             (entry point: detect CLI vs GUI mode)
      AppDelegate.swift      (NSApplicationDelegate, menu bar setup)
      MenuBuilder.swift      (builds NSMenu for each state)
      StatusManager.swift    (polls status.json, manages state transitions)
      IconManager.swift      (status bar icon + dot composition + animation)
    Backup/
      BackupEngine.swift     (main backup logic: walk, copy, hardlink)
      FileScanner.swift      (directory walking with exclude filtering)
      ExcludeFilter.swift    (glob pattern matching)
      HardLinker.swift       (compare files, create hard links)
      RetentionManager.swift (prune old backups)
      IOPriority.swift       (setiopolicy_np, battery detection)
    Config/
      ConfigManager.swift    (TOML parse/write)
      ScheduleManager.swift  (LaunchAgent plist management)
    CLI/
      CLIHandler.swift       (argument parsing, CLI commands)
    UI/
      ProgressBarView.swift  (gradient progress bar for menu)
      SpeedometerView.swift  (Ferrari gauge for menu)
      DesignTokens.swift     (MLColor, MLText, Fmt helpers)
    Diagnostics/
      DiskDiagnostics.swift  (write test, encryption check, space check)
      FDACheck.swift         (Full Disk Access probe)
      ErrorReporter.swift    (categorize and display errors)
  Resources/
    icons/                   (PNG status bar icons)
    AppIcon.icns
  Tests/
    BackupEngineTests.swift
    ExcludeFilterTests.swift
    RetentionTests.swift
    ConfigParserTests.swift
```

## Critical Implementation Details

### copyfile() for APFS Clone
```swift
import Darwin
// Use copyfile() with COPYFILE_CLONE flag for APFS copy-on-write
let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL)
let result = copyfile(sourcePath, destPath, nil, flags)
// Falls back to byte copy automatically if clone not possible
```

### I/O Priority
```swift
// From sys/resource.h
let IOPOL_TYPE_DISK: Int32 = 1
let IOPOL_SCOPE_PROCESS: Int32 = 0
let IOPOL_DEFAULT: Int32 = 0
let IOPOL_THROTTLE: Int32 = 3
setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, onBattery ? IOPOL_THROTTLE : IOPOL_DEFAULT)
```

### Hard Link Check
```swift
// Compare size + mtime to determine if file changed
let srcAttr = try FileManager.default.attributesOfItem(atPath: source)
let prevAttr = try FileManager.default.attributesOfItem(atPath: previousBackup)
if srcAttr[.size] == prevAttr[.size] && srcAttr[.modificationDate] == prevAttr[.modificationDate] {
    try FileManager.default.linkItem(atPath: previousBackup, toPath: dest)  // hard link
} else {
    copyfile(source, dest, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL))  // copy/clone
}
```

### Volume Mount Detection
```swift
// Detect real mount vs stale mountpoint
func isVolumeReallyMounted(_ path: String) -> Bool {
    var statBuf = statfs()
    var rootBuf = statfs()
    guard statfs(path, &statBuf) == 0, statfs("/", &rootBuf) == 0 else { return false }
    // If mount device matches root, it's a stale mountpoint
    return withUnsafeBytes(of: &statBuf.f_mntfromname) { pathDev in
        withUnsafeBytes(of: &rootBuf.f_mntfromname) { rootDev in
            pathDev.prefix(32) != rootDev.prefix(32)
        }
    }
}
```

## Performance Goals

This app must be FAST. Not "fast for a backup tool" — actually fast.

- **File scanning**: 100k+ files in <3 seconds (use `FileManager.enumerator` with `keys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]` to batch metadata fetches)
- **File copy**: use `copyfile()` with `COPYFILE_CLONE` — on APFS volumes this is instant (copy-on-write), degrades gracefully to byte copy on HFS+/FAT
- **Hard link check**: compare only size + mtime (no checksums — same strategy as rsync)
- **Parallel I/O**: `TaskGroup` with concurrency limit of 8 workers for file operations
- **Memory**: stay under 50MB RSS even during large backups — stream files, don't buffer full directory trees in memory
- **Startup**: menu bar app launches in <0.5s — defer all heavy work (disk check, status read) to after first paint

## What NOT to Do

- Do NOT use SwiftUI for the menu (NSMenu is required for attributed strings, custom views, dynamic items)
- Do NOT use external dependencies (no SPM packages) — everything is achievable with Foundation + AppKit
- Do NOT use Combine — use simple callbacks and GCD
- Do NOT use Core Data — plain JSON files for status, TOML for config
- Do NOT hardcode paths outside the app bundle — everything relative to bundle or ~
- Do NOT show raw error messages to users — always provide actionable fix instructions in Italian
- Do NOT make the UI feel "developer-y" — this should feel like an Apple app, polished for normal humans
- Do NOT block the main thread — ever. All I/O on background queues, all UI updates on main queue

## Testing

Write XCTest unit tests for:
1. Exclude filter glob matching (*, ?, nested paths)
2. Retention pruning logic (which backups to keep/remove)
3. Config TOML parsing and serialization
4. Backup snapshot naming and listing
5. Hard link decision logic (size + mtime comparison)

## Build & Distribution

- Build with `swiftc` or `xcodebuild` — keep it simple
- Create `build.sh` that compiles, builds .app bundle, copies to /Applications
- Create `build-pkg.sh` for .pkg installer distribution
- The .app bundle IS the product — no separate CLI binary needed
