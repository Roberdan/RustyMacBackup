use anyhow::{Context, Result};
use chrono::Local;
use colored::Colorize;
use filetime::FileTime;
use indicatif::{ProgressBar, ProgressStyle};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

use crate::config::Config;
use crate::exclude::ExcludeFilter;

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

/// Minimum free space required to start a backup (1 GB)
const MIN_FREE_SPACE: u64 = 1_073_741_824;

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

/// Clean up stale .in-progress directories from failed backups
fn cleanup_stale_in_progress(dest_base: &Path) -> Result<()> {
    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(".in-progress-") && entry.file_type()?.is_dir() {
            println!("  {} removing stale {}", "🧹".to_string(), name);
            fs::remove_dir_all(entry.path())?;
        }
    }
    Ok(())
}

pub fn run_backup(config: &Config) -> Result<BackupStats> {
    let source = &config.source.path;
    let dest_base = &config.destination.path;
    let filter = ExcludeFilter::new(&config.exclude.patterns);

    // Ensure destination exists
    fs::create_dir_all(dest_base)?;

    // Clean up stale .in-progress dirs from previous failed runs
    cleanup_stale_in_progress(dest_base)?;

    // Check disk space before starting
    let free_space = check_disk_space(dest_base)?;
    if free_space < MIN_FREE_SPACE {
        println!("{}", "⚠ Low disk space! Running auto-prune...".yellow().bold());
        // Auto-prune with aggressive policy
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

        // Re-check after prune
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
    let in_progress = dest_base.join(format!(".in-progress-{}", timestamp));
    let final_path = dest_base.join(&timestamp);

    fs::create_dir_all(&in_progress)?;

    // Write lock file
    let lock_path = dest_base.join(".rmb.lock");
    if lock_path.exists() {
        anyhow::bail!("Another backup is in progress (lock file exists: {})", lock_path.display());
    }
    fs::write(&lock_path, format!("pid:{}\nstarted:{}\n", std::process::id(), timestamp))?;

    // Count files first for progress bar
    println!("{}", "Scanning files...".dimmed());
    let file_count = WalkDir::new(source)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            if let Ok(rel) = e.path().strip_prefix(source) {
                !filter.is_excluded(rel)
            } else {
                true
            }
        })
        .count() as u64;

    let pb = ProgressBar::new(file_count);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:40.cyan/blue}] {pos}/{len} {msg}")
            .unwrap()
            .progress_chars("█▓░"),
    );

    let mut stats = BackupStats::new();

    for entry in WalkDir::new(source)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        let relative = match path.strip_prefix(source) {
            Ok(r) => r,
            Err(_) => continue,
        };

        // Skip excluded
        if filter.is_excluded(relative) {
            pb.inc(1);
            continue;
        }

        let dest_path = in_progress.join(relative);

        if entry.file_type().is_dir() {
            if let Err(e) = fs_create_dir(&dest_path) {
                stats.errors.push(format!("mkdir {}: {}", dest_path.display(), e));
            } else {
                stats.dirs_created += 1;
            }
        } else if entry.file_type().is_file() {
            match process_file(path, &dest_path, relative, &latest) {
                Ok(FileAction::HardLinked) => stats.files_hardlinked += 1,
                Ok(FileAction::Copied(size)) => {
                    stats.files_copied += 1;
                    stats.bytes_copied += size;
                }
                Err(e) => {
                    stats.errors.push(format!("{}: {}", relative.display(), e));
                }
            }
        }
        // Skip symlinks

        pb.inc(1);
        if stats.total_files() % 500 == 0 {
            pb.set_message(format!("{} linked, {} copied", stats.files_hardlinked, stats.files_copied));
        }
    }

    pb.finish_with_message(format!(
        "{} linked, {} copied",
        stats.files_hardlinked, stats.files_copied
    ));

    // Rename .in-progress to final
    fs::rename(&in_progress, &final_path)
        .context("Failed to finalize backup")?;

    // Remove lock
    let _ = fs::remove_file(&lock_path);

    Ok(stats)
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

    // Copy the file
    if let Some(parent) = dest_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let size = fs::copy(source_path, dest_path)?;

    // Preserve modification time
    let meta = fs::metadata(source_path)?;
    let mtime = FileTime::from_last_modification_time(&meta);
    filetime::set_file_mtime(dest_path, mtime)?;

    Ok(FileAction::Copied(size))
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
            source: crate::config::SourceConfig { path: source.to_path_buf() },
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
        fs::write(dest.path().join(".rmb.lock"), "pid:99\n").unwrap();

        let config = test_config(source.path(), dest.path());
        assert!(run_backup(&config).is_err());
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
        fs::create_dir(dest.path().join(".in-progress-abc")).unwrap();

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
        fs::create_dir(dest.path().join(".in-progress-old")).unwrap();
        fs::write(dest.path().join(".in-progress-old/junk.txt"), "stale").unwrap();

        let config = test_config(source.path(), dest.path());
        let _stats = run_backup(&config).unwrap();

        assert!(!dest.path().join(".in-progress-old").exists());
    }
}
