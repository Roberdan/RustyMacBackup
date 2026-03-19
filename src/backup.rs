use anyhow::{Context, Result};
use chrono::Local;
use colored::Colorize;
use filetime::FileTime;
use indicatif::{ProgressBar, ProgressStyle};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufReader, BufWriter, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Instant;
use walkdir::WalkDir;

use crate::config::Config;
use crate::exclude::ExcludeFilter;

/// 256KB I/O buffer for file copies
const BUF_SIZE: usize = 256 * 1024;

/// Update status file every N files processed
const STATUS_UPDATE_INTERVAL: u64 = 500;

/// Minimum free space required to start a backup (1 GB)
const MIN_FREE_SPACE: u64 = 1_073_741_824;

// macOS I/O policy constants (sys/resource.h)
const IOPOL_TYPE_DISK: i32 = 1;
const IOPOL_SCOPE_PROCESS: i32 = 0;
const IOPOL_DEFAULT: i32 = 0;
const IOPOL_THROTTLE: i32 = 3;

unsafe extern "C" {
    fn setiopolicy_np(iotype: i32, scope: i32, policy: i32) -> i32;
}

pub struct BackupStats {
    pub files_hardlinked: u64,
    pub files_copied: u64,
    pub dirs_created: u64,
    pub bytes_copied: u64,
    pub errors: Vec<String>,
}

impl BackupStats {
    fn new() -> Self {
        Self {
            files_hardlinked: 0,
            files_copied: 0,
            dirs_created: 0,
            bytes_copied: 0,
            errors: Vec::new(),
        }
    }

    pub fn total_files(&self) -> u64 {
        self.files_hardlinked + self.files_copied
    }
}

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct BackupStatusFile {
    pub state: String,
    pub started_at: String,
    pub last_completed: String,
    pub last_duration_secs: f64,
    pub files_total: u64,
    pub files_done: u64,
    pub bytes_copied: u64,
    pub bytes_per_sec: u64,
    pub eta_secs: u64,
    pub errors: u64,
    pub current_file: String,
}

pub fn status_file_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/rusty-mac-backup/status.json")
}

pub fn errors_file_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home)
        .join(".local/share/rusty-mac-backup/errors.json")
}

fn write_errors(errors: &[String]) {
    let path = errors_file_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    // Categorize errors for easy consumption
    let mut permission_denied: Vec<&str> = Vec::new();
    let mut not_found: Vec<&str> = Vec::new();
    let mut io_errors: Vec<&str> = Vec::new();
    let mut other: Vec<&str> = Vec::new();

    for err in errors {
        if err.contains("Operation not permitted") || err.contains("Permission denied") {
            permission_denied.push(err);
        } else if err.contains("No such file") {
            not_found.push(err);
        } else if err.contains("Input/output error") || err.contains("I/O error") {
            io_errors.push(err);
        } else {
            other.push(err);
        }
    }

    let json = serde_json::json!({
        "total": errors.len(),
        "timestamp": Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string(),
        "categories": {
            "permission_denied": {
                "count": permission_denied.len(),
                "files": permission_denied.iter().take(50).collect::<Vec<_>>()
            },
            "not_found": {
                "count": not_found.len(),
                "files": not_found.iter().take(50).collect::<Vec<_>>()
            },
            "io_error": {
                "count": io_errors.len(),
                "files": io_errors.iter().take(50).collect::<Vec<_>>()
            },
            "other": {
                "count": other.len(),
                "files": other.iter().take(50).collect::<Vec<_>>()
            }
        }
    });

    if let Ok(json_str) = serde_json::to_string_pretty(&json) {
        let _ = fs::write(&path, json_str);
    }
}

fn read_previous_status() -> BackupStatusFile {
    let path = status_file_path();
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_status(status: &BackupStatusFile) {
    let path = status_file_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(status) {
        let _ = fs::write(&path, json);
    }
}

pub fn write_error_status() {
    let prev = read_previous_status();
    write_status(&BackupStatusFile {
        state: "error".to_string(),
        errors: prev.errors + 1,
        ..prev
    });
}

/// Set I/O priority: THROTTLE on battery, DEFAULT (full speed) when plugged in
fn set_io_priority() {
    let policy = if is_on_battery() { IOPOL_THROTTLE } else { IOPOL_DEFAULT };
    unsafe {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, policy);
    }
}

fn is_on_battery() -> bool {
    std::process::Command::new("pmset")
        .args(["-g", "batt"])
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).contains("'Battery Power'"))
        .unwrap_or(false)
}

/// Check available disk space on the destination volume
fn check_disk_space(path: &Path) -> Result<u64> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    let c_path = CString::new(path.to_string_lossy().as_bytes())?;
    let mut stat: MaybeUninit<libc::statfs> = MaybeUninit::uninit();
    let result = unsafe { libc::statfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if result != 0 {
        anyhow::bail!("Failed to check disk space for {}", path.display());
    }
    let stat = unsafe { stat.assume_init() };
    Ok(stat.f_bavail as u64 * stat.f_bsize as u64)
}

/// Handle stale in-progress directories from failed/interrupted backups.
/// If the dir has actual content, finalize it as a completed backup (rename).
/// If empty, remove it. Also handles old-style .in-progress-* dirs.
fn cleanup_stale_in_progress(dest_base: &Path) -> Result<()> {
    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        // Match both new "in-progress-*" and old ".in-progress-*" format
        let is_in_progress = name.starts_with("in-progress-") || name.starts_with(".in-progress-");
        if is_in_progress && entry.file_type()?.is_dir() {
            let has_content = fs::read_dir(entry.path())
                .map(|mut d| d.next().is_some())
                .unwrap_or(false);

            if has_content {
                let timestamp = name.trim_start_matches('.').trim_start_matches("in-progress-");
                let final_name = dest_base.join(timestamp);
                if !final_name.exists() {
                    println!("  {} recovering interrupted backup {}", "↻".yellow(), timestamp);
                    fs::rename(entry.path(), &final_name)?;
                } else {
                    println!("  {} removing duplicate stale {}", "x".red(), name);
                    fs::remove_dir_all(entry.path())?;
                }
            } else {
                let _ = fs::remove_dir(entry.path());
            }
        }
        // Also clean up old .rmb.lock files
        if name == ".rmb.lock" {
            let _ = fs::remove_file(entry.path());
        }
    }
    Ok(())
}

/// Entry collected during the single-pass directory walk
struct CollectedEntry {
    source_path: PathBuf,
    dest_path: PathBuf,
    link_relative: PathBuf,
}

fn format_rate(bytes_per_sec: u64) -> String {
    const MB: u64 = 1024 * 1024;
    const KB: u64 = 1024;
    if bytes_per_sec >= MB {
        format!("{:.1} MB", bytes_per_sec as f64 / MB as f64)
    } else if bytes_per_sec >= KB {
        format!("{:.0} KB", bytes_per_sec as f64 / KB as f64)
    } else {
        format!("{} B", bytes_per_sec)
    }
}

pub fn run_backup(config: &Config) -> Result<BackupStats> {
    let sources = config.source.all_paths();
    let dest_base = &config.destination.path;
    let filter = ExcludeFilter::new(&config.exclude.patterns);

    if sources.is_empty() {
        anyhow::bail!("No source paths configured");
    }

    // Adaptive I/O priority: THROTTLE on battery, UTILITY when plugged in
    set_io_priority();

    // Ensure destination exists
    fs::create_dir_all(dest_base)?;

    // Clean up stale .in-progress dirs from previous failed runs
    cleanup_stale_in_progress(dest_base)?;

    // Check disk space before starting
    let free_space = check_disk_space(dest_base)?;
    if free_space < MIN_FREE_SPACE {
        println!("{}", "\u{26a0} Low disk space! Running auto-prune...".yellow().bold());
        let policy = crate::retention::RetentionPolicy {
            hourly: config.retention.hourly,
            daily: config.retention.daily,
            weekly: config.retention.weekly,
            monthly: config.retention.monthly,
        };
        let pruned = crate::retention::prune_backups(dest_base, &policy)?;
        if !pruned.is_empty() {
            println!("  Pruned {} old backups to free space", pruned.len());
        }

        let free_after = check_disk_space(dest_base)?;
        if free_after < MIN_FREE_SPACE {
            anyhow::bail!(
                "Not enough disk space: {:.1} GB free (need at least 1 GB). \
                 Consider adding more exclusions or reducing retention.",
                free_after as f64 / 1_073_741_824.0
            );
        }
    }

    // Find latest existing backup for hard-linking
    let latest = find_latest_backup(dest_base)?;

    // Create new backup dir as .in-progress
    let timestamp = Local::now().format("%Y-%m-%d_%H%M%S").to_string();
    let in_progress = dest_base.join(format!("in-progress-{}", timestamp));
    let final_path = dest_base.join(&timestamp);

    fs::create_dir_all(&in_progress)?;

    // Write lock file (clean up stale locks from crashed backups)
    let lock_path = dest_base.join("rustyback.lock");
    if lock_path.exists() {
        // Check if the PID in the lock file is still alive
        let lock_content = fs::read_to_string(&lock_path).unwrap_or_default();
        let stale = if let Some(pid_str) = lock_content.lines()
            .find(|l| l.starts_with("pid:"))
            .and_then(|l| l.strip_prefix("pid:"))
        {
            if let Ok(pid) = pid_str.trim().parse::<i32>() {
                // kill(pid, 0) checks if process exists without sending a signal
                let alive = unsafe { libc::kill(pid, 0) } == 0;
                !alive
            } else {
                true // Can't parse PID — stale
            }
        } else {
            true // No PID in lock — stale
        };

        if stale {
            println!("  {} removing stale lock (process no longer running)", "x".red());
            let _ = fs::remove_file(&lock_path);
        } else {
            anyhow::bail!("Another backup is in progress (lock file exists: {})", lock_path.display());
        }
    }
    fs::write(&lock_path, format!("pid:{}\nstarted:{}\n", std::process::id(), timestamp))?;

    let start_time = Instant::now();
    let started_at = Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string();
    let prev_status = read_previous_status();

    // Phase 1: Single-pass directory walk with exclude pruning
    // filter_entry() prevents WalkDir from descending into excluded directories,
    // which is critical for performance (avoids walking Library/Caches, node_modules, etc.)
    let scan_pb = ProgressBar::new_spinner();
    scan_pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} Scanning... {msg}")
            .unwrap(),
    );
    scan_pb.enable_steady_tick(std::time::Duration::from_millis(120));

    let mut dir_entries: Vec<CollectedEntry> = Vec::new();
    let mut file_entries: Vec<CollectedEntry> = Vec::new();
    let mut source_errors: Vec<String> = Vec::new();
    let mut scan_count: u64 = 0;

    for source in &sources {
        if !source.exists() {
            source_errors.push(format!("Source not found: {}", source.display()));
            continue;
        }

        let prefix = source.strip_prefix("/").unwrap_or(source);
        let source_path: &Path = source.as_ref();

        for entry in WalkDir::new(source)
            .into_iter()
            .filter_entry(|e| {
                let path = e.path();
                match path.strip_prefix(source_path) {
                    Ok(r) if r.as_os_str().is_empty() => true,
                    Ok(r) => !filter.is_excluded(r),
                    Err(_) => true,
                }
            })
            .filter_map(|e| e.ok())
        {
            let path = entry.path();
            let relative = match path.strip_prefix(source) {
                Ok(r) => r,
                Err(_) => continue,
            };

            let dest_path = in_progress.join(prefix).join(relative);
            let link_relative = prefix.join(relative);

            if entry.file_type().is_dir() {
                dir_entries.push(CollectedEntry {
                    source_path: path.to_path_buf(),
                    dest_path,
                    link_relative,
                });
            } else if entry.file_type().is_file() {
                file_entries.push(CollectedEntry {
                    source_path: path.to_path_buf(),
                    dest_path,
                    link_relative,
                });
            }

            scan_count += 1;
            if scan_count % 5_000 == 0 {
                scan_pb.set_message(format!(
                    "{} entries ({} files, {} dirs)",
                    scan_count, file_entries.len(), dir_entries.len()
                ));
            }
        }
    }

    scan_pb.finish_and_clear();

    println!(
        "{}",
        format!(
            "Found {} files, {} dirs (scanned in {:.1}s)",
            file_entries.len(),
            dir_entries.len(),
            start_time.elapsed().as_secs_f64()
        )
        .dimmed()
    );

    let total_entries = (dir_entries.len() + file_entries.len()) as u64;
    let file_count = file_entries.len() as u64;

    // Write initial "running" status
    write_status(&BackupStatusFile {
        state: "running".to_string(),
        started_at: started_at.clone(),
        last_completed: prev_status.last_completed.clone(),
        last_duration_secs: prev_status.last_duration_secs,
        files_total: file_count,
        files_done: 0,
        bytes_copied: 0,
        bytes_per_sec: 0,
        eta_secs: 0,
        errors: 0,
        current_file: String::new(),
    });

    let pb = ProgressBar::new(total_entries);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:40.cyan/blue}] {pos}/{len} {msg}")
            .unwrap()
            .progress_chars("\u{2588}\u{2593}\u{2591}"),
    );

    // Phase 2: Create directories (sequential, parent-before-child ordering)
    let mut dirs_created: u64 = 0;
    let mut dir_errors: Vec<String> = Vec::new();
    for entry in &dir_entries {
        if let Err(e) = fs_create_dir(&entry.dest_path) {
            dir_errors.push(format!("mkdir {}: {}", entry.dest_path.display(), e));
        } else {
            dirs_created += 1;
        }
        pb.inc(1);
    }

    // Phase 3: Process files in parallel with rayon
    let a_hardlinked = AtomicU64::new(0);
    let a_copied = AtomicU64::new(0);
    let a_bytes = AtomicU64::new(0);
    let a_done = AtomicU64::new(0);
    let disk_disconnected = AtomicBool::new(false);
    let file_errs: Mutex<Vec<String>> = Mutex::new(Vec::new());

    file_entries.par_iter().for_each(|entry| {
        // If another thread detected disk disconnect, skip immediately
        if disk_disconnected.load(Ordering::Relaxed) {
            return;
        }

        // Periodically check if the destination disk is still connected
        let done_so_far = a_done.load(Ordering::Relaxed);
        if done_so_far > 0 && done_so_far % 100 == 0 && !in_progress.exists() {
            disk_disconnected.store(true, Ordering::Relaxed);
            return;
        }

        match process_file(&entry.source_path, &entry.dest_path, &entry.link_relative, &latest) {
            Ok(FileAction::HardLinked) => {
                a_hardlinked.fetch_add(1, Ordering::Relaxed);
            }
            Ok(FileAction::Copied(size)) => {
                a_copied.fetch_add(1, Ordering::Relaxed);
                a_bytes.fetch_add(size, Ordering::Relaxed);
            }
            Err(e) => {
                // An I/O error may indicate disk disconnect
                let msg = e.to_string();
                if msg.contains("No such file or directory") || msg.contains("Input/output error") {
                    if !in_progress.exists() {
                        disk_disconnected.store(true, Ordering::Relaxed);
                        return;
                    }
                }
                if let Ok(mut errs) = file_errs.lock() {
                    errs.push(format!("{}: {}", entry.link_relative.display(), e));
                }
            }
        }

        let done = a_done.fetch_add(1, Ordering::Relaxed) + 1;
        pb.inc(1);

        // Update progress + status file every STATUS_UPDATE_INTERVAL files
        if done % STATUS_UPDATE_INTERVAL == 0 {
            let elapsed = start_time.elapsed().as_secs_f64();
            let bytes_now = a_bytes.load(Ordering::Relaxed);
            let bps = if elapsed > 0.0 { (bytes_now as f64 / elapsed) as u64 } else { 0 };
            let eta = if done > 0 && elapsed > 0.0 {
                let fps = done as f64 / elapsed;
                (file_count.saturating_sub(done) as f64 / fps) as u64
            } else {
                0
            };

            pb.set_message(format!(
                "{} linked, {} copied | {}/s ETA {}s",
                a_hardlinked.load(Ordering::Relaxed),
                a_copied.load(Ordering::Relaxed),
                format_rate(bps),
                eta,
            ));

            write_status(&BackupStatusFile {
                state: "running".to_string(),
                started_at: started_at.clone(),
                last_completed: prev_status.last_completed.clone(),
                last_duration_secs: prev_status.last_duration_secs,
                files_total: file_count,
                files_done: done,
                bytes_copied: bytes_now,
                bytes_per_sec: bps,
                eta_secs: eta,
                errors: file_errs.lock().map(|e| e.len() as u64).unwrap_or(0),
                current_file: entry.link_relative.to_string_lossy().to_string(),
            });
        }
    });

    // Handle disk disconnection detected during backup
    if disk_disconnected.load(Ordering::Relaxed) {
        let _ = fs::remove_file(&lock_path);
        write_error_status();
        anyhow::bail!("Backup disk was disconnected during backup!");
    }

    let files_hardlinked = a_hardlinked.load(Ordering::Relaxed);
    let files_copied = a_copied.load(Ordering::Relaxed);
    let bytes_copied = a_bytes.load(Ordering::Relaxed);

    pb.finish_with_message(format!(
        "{} linked, {} copied",
        files_hardlinked, files_copied
    ));

    // Rename .in-progress to final
    fs::rename(&in_progress, &final_path)
        .context("Failed to finalize backup")?;

    // Remove lock
    let _ = fs::remove_file(&lock_path);

    // Collect all errors
    let mut all_errors = source_errors;
    all_errors.extend(dir_errors);
    if let Ok(fe) = file_errs.into_inner() {
        all_errors.extend(fe);
    }

    // Write errors to disk for menu bar and CLI consumption
    write_errors(&all_errors);

    // Write "idle" status with completion info
    let duration = start_time.elapsed();
    let completed_at = Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string();
    write_status(&BackupStatusFile {
        state: "idle".to_string(),
        started_at,
        last_completed: completed_at,
        last_duration_secs: duration.as_secs_f64(),
        files_total: file_count,
        files_done: file_count,
        bytes_copied,
        bytes_per_sec: if duration.as_secs_f64() > 0.0 {
            (bytes_copied as f64 / duration.as_secs_f64()) as u64
        } else {
            0
        },
        eta_secs: 0,
        errors: all_errors.len() as u64,
        current_file: String::new(),
    });

    Ok(BackupStats {
        files_hardlinked,
        files_copied,
        dirs_created,
        bytes_copied,
        errors: all_errors,
    })
}

enum FileAction {
    HardLinked,
    Copied(u64),
}

fn process_file(
    source_path: &Path,
    dest_path: &Path,
    relative: &Path,
    latest_backup: &Option<PathBuf>,
) -> Result<FileAction> {
    // Try hard-linking from previous backup if file unchanged
    if let Some(prev_backup) = latest_backup {
        let prev_file = prev_backup.join(relative);
        if prev_file.exists() && files_match(source_path, &prev_file)? {
            if let Some(parent) = dest_path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::hard_link(&prev_file, dest_path)?;
            return Ok(FileAction::HardLinked);
        }
    }

    // Copy the file using buffered I/O
    if let Some(parent) = dest_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let size = buffered_copy(source_path, dest_path)?;

    // Preserve modification time
    let meta = fs::metadata(source_path)?;
    let mtime = FileTime::from_last_modification_time(&meta);
    filetime::set_file_mtime(dest_path, mtime)?;

    Ok(FileAction::Copied(size))
}

/// Copy a file using 256KB buffered I/O for optimal throughput
fn buffered_copy(src: &Path, dest: &Path) -> Result<u64> {
    let source_file = fs::File::open(src)?;
    let dest_file = fs::File::create(dest)?;
    let mut reader = BufReader::with_capacity(BUF_SIZE, source_file);
    let mut writer = BufWriter::with_capacity(BUF_SIZE, dest_file);
    let bytes = std::io::copy(&mut reader, &mut writer)?;
    writer.flush()?;
    Ok(bytes)
}

fn files_match(a: &Path, b: &Path) -> Result<bool> {
    let meta_a = fs::metadata(a)?;
    let meta_b = fs::metadata(b)?;

    // Compare size and modification time
    Ok(meta_a.size() == meta_b.size()
        && meta_a.mtime() == meta_b.mtime()
        && meta_a.mtime_nsec() == meta_b.mtime_nsec())
}

fn fs_create_dir(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::create_dir_all(path)?;
    }
    Ok(())
}

pub fn find_latest_backup(dest_base: &Path) -> Result<Option<PathBuf>> {
    let mut backups: Vec<PathBuf> = Vec::new();

    if !dest_base.exists() {
        return Ok(None);
    }

    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        // Match YYYY-MM-DD_HHMMSS format
        if name.len() == 17 && name.chars().nth(4) == Some('-') && entry.file_type()?.is_dir() {
            backups.push(entry.path());
        }
    }

    backups.sort();
    Ok(backups.last().cloned())
}

pub fn list_backups(dest_base: &Path) -> Result<Vec<(String, u64)>> {
    let mut backups: Vec<(String, u64)> = Vec::new();

    if !dest_base.exists() {
        return Ok(backups);
    }

    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.len() == 17 && name.chars().nth(4) == Some('-') && entry.file_type()?.is_dir() {
            // Count files in backup
            let count = WalkDir::new(entry.path())
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().is_file())
                .count() as u64;
            backups.push((name, count));
        }
    }

    backups.sort();
    Ok(backups)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn test_config(source: &Path, dest: &Path) -> Config {
        Config {
            source: crate::config::SourceConfig { 
                path: source.to_path_buf(),
                extra_paths: vec![],
            },
            destination: crate::config::DestinationConfig { path: dest.to_path_buf() },
            exclude: crate::config::ExcludeConfig { patterns: vec!["*.tmp".to_string(), "node_modules".to_string()] },
            retention: crate::config::RetentionConfig { hourly: 24, daily: 30, weekly: 52, monthly: 0 },
        }
    }

    #[test]
    fn test_first_backup_copies_all() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("file1.txt"), "hello").unwrap();
        fs::create_dir(source.path().join("subdir")).unwrap();
        fs::write(source.path().join("subdir/file2.txt"), "world").unwrap();

        let config = test_config(source.path(), dest.path());
        let stats = run_backup(&config).unwrap();

        assert_eq!(stats.files_copied, 2);
        assert_eq!(stats.files_hardlinked, 0);
        assert!(stats.errors.is_empty());
    }

    #[test]
    fn test_incremental_hardlinks_unchanged() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("stable.txt"), "unchanged").unwrap();
        fs::write(source.path().join("changing.txt"), "v1").unwrap();

        let config = test_config(source.path(), dest.path());
        let _stats1 = run_backup(&config).unwrap();

        std::thread::sleep(std::time::Duration::from_secs(1));

        fs::write(source.path().join("changing.txt"), "v2").unwrap();
        let stats2 = run_backup(&config).unwrap();

        assert_eq!(stats2.files_hardlinked, 1); // stable.txt
        assert_eq!(stats2.files_copied, 1);     // changing.txt
    }

    #[test]
    fn test_excludes_skip_files() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("keep.txt"), "keep").unwrap();
        fs::write(source.path().join("skip.tmp"), "skip").unwrap();
        fs::create_dir(source.path().join("node_modules")).unwrap();
        fs::write(source.path().join("node_modules/pkg.json"), "{}").unwrap();

        let config = test_config(source.path(), dest.path());
        let stats = run_backup(&config).unwrap();

        assert_eq!(stats.files_copied, 1);
    }

    #[test]
    fn test_lock_prevents_concurrent() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("f.txt"), "t").unwrap();
        // Use current PID so the lock looks active (not stale)
        let my_pid = std::process::id();
        fs::write(dest.path().join("rustyback.lock"), format!("pid:{}\n", my_pid)).unwrap();

        let config = test_config(source.path(), dest.path());
        assert!(run_backup(&config).is_err());
    }

    #[test]
    fn test_stale_lock_gets_cleaned() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("f.txt"), "data").unwrap();
        // PID 99999999 doesn't exist — lock is stale
        fs::write(dest.path().join("rustyback.lock"), "pid:99999999\n").unwrap();

        let config = test_config(source.path(), dest.path());
        // Should succeed because stale lock is cleaned up
        assert!(run_backup(&config).is_ok());
    }

    #[test]
    fn test_find_latest_empty() {
        let dest = TempDir::new().unwrap();
        assert!(find_latest_backup(dest.path()).unwrap().is_none());
    }

    #[test]
    fn test_find_latest_picks_newest() {
        let dest = TempDir::new().unwrap();
        fs::create_dir(dest.path().join("2026-03-17_100000")).unwrap();
        fs::create_dir(dest.path().join("2026-03-19_100000")).unwrap();
        fs::create_dir(dest.path().join("2026-03-18_100000")).unwrap();

        let latest = find_latest_backup(dest.path()).unwrap().unwrap();
        assert!(latest.ends_with("2026-03-19_100000"));
    }

    #[test]
    fn test_list_backups_sorted_ignores_in_progress() {
        let dest = TempDir::new().unwrap();
        fs::create_dir(dest.path().join("2026-03-18_100000")).unwrap();
        fs::create_dir(dest.path().join("2026-03-17_100000")).unwrap();
        fs::create_dir(dest.path().join("in-progress-abc")).unwrap();

        let backups = list_backups(dest.path()).unwrap();
        assert_eq!(backups.len(), 2);
        assert_eq!(backups[0].0, "2026-03-17_100000");
        assert_eq!(backups[1].0, "2026-03-18_100000");
    }

    #[test]
    fn test_stale_in_progress_cleaned() {
        let source = TempDir::new().unwrap();
        let dest = TempDir::new().unwrap();

        fs::write(source.path().join("f.txt"), "data").unwrap();
        fs::create_dir(dest.path().join("in-progress-old")).unwrap();
        fs::write(dest.path().join("in-progress-old/junk.txt"), "stale").unwrap();

        let config = test_config(source.path(), dest.path());
        let _stats = run_backup(&config).unwrap();

        assert!(!dest.path().join("in-progress-old").exists());
    }
}
