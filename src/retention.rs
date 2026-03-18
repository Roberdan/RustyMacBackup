use anyhow::Result;
use chrono::{NaiveDateTime, Utc, Duration};
use colored::Colorize;
use std::fs;
use std::path::Path;

pub struct RetentionPolicy {
    pub hourly: u32,
    pub daily: u32,
    pub weekly: u32,
    pub monthly: u32,
}

struct BackupEntry {
    name: String,
    timestamp: NaiveDateTime,
}

pub fn prune_backups(dest_base: &Path, policy: &RetentionPolicy) -> Result<Vec<String>> {
    let mut entries: Vec<BackupEntry> = Vec::new();

    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(ts) = parse_backup_name(&name) {
            entries.push(BackupEntry { name, timestamp: ts });
        }
    }

    entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp)); // newest first

    let now = Utc::now().naive_utc();
    let mut keep: Vec<bool> = vec![false; entries.len()];
    let mut pruned: Vec<String> = Vec::new();

    // Always keep the latest
    if !entries.is_empty() {
        keep[0] = true;
    }

    // Hourly: keep one per hour for the last N hours
    if policy.hourly > 0 {
        mark_keep_by_interval(&entries, &mut keep, now, Duration::hours(1), policy.hourly);
    }

    // Daily: keep one per day for the last N days
    if policy.daily > 0 {
        mark_keep_by_interval(&entries, &mut keep, now, Duration::days(1), policy.daily);
    }

    // Weekly: keep one per week for the last N weeks
    if policy.weekly > 0 {
        mark_keep_by_interval(&entries, &mut keep, now, Duration::weeks(1), policy.weekly);
    }

    // Monthly: keep one per 30 days (0 = keep all monthly forever)
    if policy.monthly == 0 {
        // Keep at least one per month forever
        mark_keep_monthly_forever(&entries, &mut keep);
    } else {
        mark_keep_by_interval(&entries, &mut keep, now, Duration::days(30), policy.monthly);
    }

    // Delete non-kept backups
    for (i, entry) in entries.iter().enumerate() {
        if !keep[i] {
            let path = dest_base.join(&entry.name);
            println!("  {} {}", "Pruning:".red(), entry.name);
            fs::remove_dir_all(&path)?;
            pruned.push(entry.name.clone());
        }
    }

    Ok(pruned)
}

fn mark_keep_by_interval(
    entries: &[BackupEntry],
    keep: &mut [bool],
    now: NaiveDateTime,
    interval: Duration,
    count: u32,
) {
    for slot in 0..count {
        let slot_start = now - interval * (slot as i32 + 1);
        let slot_end = now - interval * slot as i32;

        // Find the most recent backup in this slot
        for (i, entry) in entries.iter().enumerate() {
            if entry.timestamp >= slot_start && entry.timestamp < slot_end {
                keep[i] = true;
                break;
            }
        }
    }
}

fn mark_keep_monthly_forever(entries: &[BackupEntry], keep: &mut [bool]) {
    let mut seen_months: Vec<(i32, u32)> = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        let year = entry.timestamp.date().year();
        let month = entry.timestamp.date().month();
        let key = (year, month);
        if !seen_months.contains(&key) {
            keep[i] = true;
            seen_months.push(key);
        }
    }
}

fn parse_backup_name(name: &str) -> Option<NaiveDateTime> {
    // Format: YYYY-MM-DD_HHMMSS
    if name.len() != 17 {
        return None;
    }
    NaiveDateTime::parse_from_str(name, "%Y-%m-%d_%H%M%S").ok()
}

use chrono::Datelike;

pub fn print_retention_summary(dest_base: &Path, policy: &RetentionPolicy) -> Result<()> {
    let mut entries: Vec<BackupEntry> = Vec::new();

    for entry in fs::read_dir(dest_base)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some(ts) = parse_backup_name(&name) {
            entries.push(BackupEntry { name, timestamp: ts });
        }
    }

    entries.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    println!("{}", "Retention policy:".bold());
    println!("  Hourly:  keep {} (last {} hours)", policy.hourly, policy.hourly);
    println!("  Daily:   keep {} (last {} days)", policy.daily, policy.daily);
    println!("  Weekly:  keep {} (last {} weeks)", policy.weekly, policy.weekly);
    if policy.monthly == 0 {
        println!("  Monthly: keep forever");
    } else {
        println!("  Monthly: keep {} (last {} months)", policy.monthly, policy.monthly);
    }
    println!();
    println!("  Total backups: {}", entries.len());

    Ok(())
}
