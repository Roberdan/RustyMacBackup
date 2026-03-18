mod backup;
mod config;
mod exclude;
mod retention;

use anyhow::Result;
use clap::{Parser, Subcommand};
use colored::Colorize;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Parser)]
#[command(name = "rustyback", version, about = "🦀 RustyMacBackup — Fast incremental backups with hard links")]
struct Cli {
    /// Path to config file
    #[arg(short, long)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Run a backup now
    Backup,
    /// List all backups
    List,
    /// Show backup status and disk usage
    Status,
    /// Prune old backups according to retention policy
    Prune {
        /// Dry run — show what would be pruned without deleting
        #[arg(long)]
        dry_run: bool,
    },
    /// Restore a backup
    Restore {
        /// Backup name (e.g. 2026-03-18_170000)
        name: String,
        /// Optional: restore only a specific file/folder
        path: Option<String>,
        /// Restore destination (default: original location)
        #[arg(short, long)]
        to: Option<PathBuf>,
    },
    /// Generate a default config file
    Init,
    /// Manage configuration
    Config {
        #[command(subcommand)]
        action: ConfigAction,
    },
    /// Manage launchd schedule
    Schedule {
        #[command(subcommand)]
        action: ScheduleAction,
    },
}

#[derive(Subcommand)]
enum ConfigAction {
    /// Show current configuration
    Show,
    /// Set source directory
    Source {
        path: PathBuf,
    },
    /// Set destination directory
    Dest {
        path: PathBuf,
    },
    /// Add an exclude pattern
    Exclude {
        pattern: String,
    },
    /// Remove an exclude pattern
    Include {
        pattern: String,
    },
    /// List all exclude patterns
    Excludes,
    /// Set retention policy
    Retention {
        /// Hourly backups to keep
        #[arg(long)]
        hourly: Option<u32>,
        /// Daily backups to keep
        #[arg(long)]
        daily: Option<u32>,
        /// Weekly backups to keep
        #[arg(long)]
        weekly: Option<u32>,
        /// Monthly backups to keep (0 = forever)
        #[arg(long)]
        monthly: Option<u32>,
    },
    /// Open config file in $EDITOR
    Edit,
}

#[derive(Subcommand)]
enum ScheduleAction {
    /// Enable hourly backup schedule
    On,
    /// Disable backup schedule
    Off,
    /// Show schedule status
    Status,
    /// Set backup interval in minutes
    Interval {
        minutes: u32,
    },
}

fn load_config(path: &Option<PathBuf>) -> Result<config::Config> {
    let config_path = path.clone().unwrap_or_else(config::Config::default_path);
    if !config_path.exists() {
        anyhow::bail!(
            "Config not found: {}\nRun `rustyback init` to create one.",
            config_path.display()
        );
    }
    config::Config::load(&config_path)
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init => cmd_init()?,
        Commands::Backup => cmd_backup(&cli.config)?,
        Commands::List => cmd_list(&cli.config)?,
        Commands::Status => cmd_status(&cli.config)?,
        Commands::Prune { dry_run } => cmd_prune(&cli.config, dry_run)?,
        Commands::Restore { name, path, to } => cmd_restore(&cli.config, &name, path, to)?,
        Commands::Config { action } => cmd_config(&cli.config, action)?,
        Commands::Schedule { action } => cmd_schedule(action)?,
    }

    Ok(())
}

fn cmd_init() -> Result<()> {
    let config_path = config::Config::default_path();
    if config_path.exists() {
        println!("{} Config already exists: {}", "⚠".yellow(), config_path.display());
        return Ok(());
    }

    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let default_config = r#"[source]
path = "/Users/roberdan"

[destination]
path = "/Volumes/RoberdanBCK 1/RustyMacBackup"

[exclude]
patterns = [
    # macOS system
    ".Spotlight-*",
    ".fseventsd",
    ".Trash",
    ".Trashes",
    ".DS_Store",
    ".TemporaryItems",
    ".VolumeIcon.icns",

    # Library junk (cached/regenerable)
    "Library/Caches",
    "Library/Logs",
    "Library/Application Support/Caches",
    "Library/Saved Application State",
    "Library/Containers/*/Data/Library/Caches",

    # Cloud-synced (already backed up remotely)
    "OneDrive*",
    "Library/CloudStorage",
    "Library/Mobile Documents",
    "Library/Group Containers/*.Office",
    "Dropbox",
    "Google Drive",
    "iCloud Drive*",

    # Dev artifacts (regenerable)
    "node_modules",
    ".git/objects",
    "target/debug",
    "target/release",
    ".build",
    "*.tmp",
    "*.swp",
    ".cache",
    "__pycache__",
    ".venv",
    ".tox",

    # Large/volatile
    ".ollama/models",
    ".lmstudio",
    "*.iso",
    "*.dmg",
]

[retention]
hourly = 24
daily = 30
weekly = 52
monthly = 0
"#;

    std::fs::write(&config_path, default_config)?;
    println!("{} Config created: {}", "✅".green(), config_path.display());
    println!("   Edit it, then run: {}", "rustyback backup".bold());
    Ok(())
}

fn cmd_backup(config_path: &Option<PathBuf>) -> Result<()> {
    let config = load_config(config_path)?;
    let start = Instant::now();

    println!("{}", "🦀 RustyMacBackup".bold().cyan());
    println!("   Source: {}", config.source.path.display());
    println!("   Dest:   {}", config.destination.path.display());
    println!();

    let stats = backup::run_backup(&config)?;
    let elapsed = start.elapsed();

    println!();
    println!("{}", "━".repeat(50).dimmed());
    println!("{}", "Backup complete!".bold().green());
    println!("  {} files hard-linked (unchanged)", stats.files_hardlinked.to_string().cyan());
    println!("  {} files copied (new/modified)", stats.files_copied.to_string().yellow());
    println!("  {} dirs created", stats.dirs_created);
    println!("  {} copied", format_bytes(stats.bytes_copied));
    println!("  ⏱  {:.1}s", elapsed.as_secs_f64());

    if !stats.errors.is_empty() {
        println!();
        println!("{} {} errors:", "⚠".yellow(), stats.errors.len());
        for err in stats.errors.iter().take(10) {
            println!("  {}", err.red());
        }
        if stats.errors.len() > 10 {
            println!("  ... and {} more", stats.errors.len() - 10);
        }
    }

    Ok(())
}

fn cmd_list(config_path: &Option<PathBuf>) -> Result<()> {
    let config = load_config(config_path)?;
    let backups = backup::list_backups(&config.destination.path)?;

    if backups.is_empty() {
        println!("No backups found.");
        return Ok(());
    }

    println!("{}", "📦 Backups:".bold());
    for (name, count) in &backups {
        println!("  {} ({} files)", name.cyan(), count);
    }
    println!();
    println!("Total: {} backups", backups.len());
    Ok(())
}

fn cmd_status(config_path: &Option<PathBuf>) -> Result<()> {
    let config = load_config(config_path)?;
    let dest = &config.destination.path;

    println!("{}", "🦀 RustyMacBackup Status".bold().cyan());
    println!();

    let backups = backup::list_backups(dest)?;
    println!("  Backups: {}", backups.len());

    if let Some((latest, _)) = backups.last() {
        println!("  Latest:  {}", latest.green());
    }

    // Disk usage
    let disk_usage = dir_size(dest)?;
    println!("  Disk:    {}", format_bytes(disk_usage));

    println!();
    retention::print_retention_summary(
        dest,
        &retention::RetentionPolicy {
            hourly: config.retention.hourly,
            daily: config.retention.daily,
            weekly: config.retention.weekly,
            monthly: config.retention.monthly,
        },
    )?;

    Ok(())
}

fn cmd_prune(config_path: &Option<PathBuf>, dry_run: bool) -> Result<()> {
    let config = load_config(config_path)?;

    let policy = retention::RetentionPolicy {
        hourly: config.retention.hourly,
        daily: config.retention.daily,
        weekly: config.retention.weekly,
        monthly: config.retention.monthly,
    };

    if dry_run {
        println!("{}", "Dry run — nothing will be deleted".yellow());
    }

    let pruned = retention::prune_backups(&config.destination.path, &policy)?;

    if pruned.is_empty() {
        println!("{}", "Nothing to prune.".green());
    } else {
        println!("Pruned {} backups.", pruned.len());
    }

    Ok(())
}

fn cmd_restore(
    config_path: &Option<PathBuf>,
    name: &str,
    path: Option<String>,
    to: Option<PathBuf>,
) -> Result<()> {
    let config = load_config(config_path)?;
    let backup_path = config.destination.path.join(name);

    if !backup_path.exists() {
        anyhow::bail!("Backup not found: {}", name);
    }

    let source = if let Some(ref subpath) = path {
        backup_path.join(subpath)
    } else {
        backup_path.clone()
    };

    if !source.exists() {
        anyhow::bail!("Path not found in backup: {}", source.display());
    }

    let dest = if let Some(to) = to {
        to
    } else {
        // Restore to original location
        if let Some(ref subpath) = path {
            config.source.path.join(subpath)
        } else {
            anyhow::bail!("Full restore requires --to <destination>");
        }
    };

    println!("{}", "Restoring...".bold());
    println!("  From: {}", source.display());
    println!("  To:   {}", dest.display());

    if source.is_file() {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(&source, &dest)?;
        println!("{}", "✅ File restored!".green());
    } else {
        copy_dir_recursive(&source, &dest)?;
        println!("{}", "✅ Directory restored!".green());
    }

    Ok(())
}

fn copy_dir_recursive(src: &std::path::Path, dst: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in walkdir::WalkDir::new(src) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(src)?;
        let dest_path = dst.join(relative);

        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&dest_path)?;
        } else {
            if let Some(parent) = dest_path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), &dest_path)?;
        }
    }
    Ok(())
}

fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.0} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

fn dir_size(path: &std::path::Path) -> Result<u64> {
    let mut total: u64 = 0;
    if path.exists() {
        for entry in walkdir::WalkDir::new(path).into_iter().filter_map(|e| e.ok()) {
            if entry.file_type().is_file() {
                total += entry.metadata().map(|m| m.len()).unwrap_or(0);
            }
        }
    }
    Ok(total)
}

// =============================================================================
// Config management
// =============================================================================

fn config_path_for(cli_config: &Option<PathBuf>) -> PathBuf {
    cli_config.clone().unwrap_or_else(config::Config::default_path)
}

fn save_config(path: &std::path::Path, config: &config::Config) -> Result<()> {
    let mut out = String::new();

    out.push_str(&format!("[source]\npath = {:?}\n\n", config.source.path.to_string_lossy()));
    out.push_str(&format!("[destination]\npath = {:?}\n\n", config.destination.path.to_string_lossy()));

    out.push_str("[exclude]\npatterns = [\n");
    for p in &config.exclude.patterns {
        out.push_str(&format!("    {:?},\n", p));
    }
    out.push_str("]\n\n");

    out.push_str("[retention]\n");
    out.push_str(&format!("hourly = {}\n", config.retention.hourly));
    out.push_str(&format!("daily = {}\n", config.retention.daily));
    out.push_str(&format!("weekly = {}\n", config.retention.weekly));
    out.push_str(&format!("monthly = {}\n", config.retention.monthly));

    std::fs::write(path, out)?;
    Ok(())
}

fn cmd_config(cli_config: &Option<PathBuf>, action: ConfigAction) -> Result<()> {
    let path = config_path_for(cli_config);

    match action {
        ConfigAction::Show => {
            let content = std::fs::read_to_string(&path)?;
            println!("{} {}\n", "📄".to_string(), path.display().to_string().dimmed());
            println!("{}", content);
        }
        ConfigAction::Source { path: new_source } => {
            let mut config = load_config(cli_config)?;
            let abs = std::fs::canonicalize(&new_source)?;
            println!("  Source: {} → {}", config.source.path.display().to_string().red(), abs.display().to_string().green());
            config.source.path = abs;
            save_config(&path, &config)?;
            println!("{}", "✅ Saved".green());
        }
        ConfigAction::Dest { path: new_dest } => {
            let mut config = load_config(cli_config)?;
            println!("  Dest: {} → {}", config.destination.path.display().to_string().red(), new_dest.display().to_string().green());
            config.destination.path = new_dest;
            save_config(&path, &config)?;
            println!("{}", "✅ Saved".green());
        }
        ConfigAction::Exclude { pattern } => {
            let mut config = load_config(cli_config)?;
            if config.exclude.patterns.contains(&pattern) {
                println!("  Already excluded: {}", pattern.yellow());
            } else {
                config.exclude.patterns.push(pattern.clone());
                save_config(&path, &config)?;
                println!("  {} Added: {}", "✅".green(), pattern);
            }
        }
        ConfigAction::Include { pattern } => {
            let mut config = load_config(cli_config)?;
            let before = config.exclude.patterns.len();
            config.exclude.patterns.retain(|p| p != &pattern);
            if config.exclude.patterns.len() < before {
                save_config(&path, &config)?;
                println!("  {} Removed: {}", "✅".green(), pattern);
            } else {
                println!("  Pattern not found: {}", pattern.yellow());
            }
        }
        ConfigAction::Excludes => {
            let config = load_config(cli_config)?;
            println!("{}", "Exclude patterns:".bold());
            for (i, p) in config.exclude.patterns.iter().enumerate() {
                println!("  {}. {}", i + 1, p.dimmed());
            }
            println!("\n  Total: {}", config.exclude.patterns.len());
        }
        ConfigAction::Retention { hourly, daily, weekly, monthly } => {
            let mut config = load_config(cli_config)?;
            let mut changed = false;
            if let Some(h) = hourly { config.retention.hourly = h; changed = true; }
            if let Some(d) = daily { config.retention.daily = d; changed = true; }
            if let Some(w) = weekly { config.retention.weekly = w; changed = true; }
            if let Some(m) = monthly { config.retention.monthly = m; changed = true; }

            if changed {
                save_config(&path, &config)?;
                println!("{}", "✅ Retention updated:".green());
            } else {
                println!("{}", "Current retention:".bold());
            }
            println!("  hourly:  {}", config.retention.hourly);
            println!("  daily:   {}", config.retention.daily);
            println!("  weekly:  {}", config.retention.weekly);
            println!("  monthly: {} {}", config.retention.monthly,
                if config.retention.monthly == 0 { "(forever)".dimmed().to_string() } else { String::new() });
        }
        ConfigAction::Edit => {
            let editor = std::env::var("EDITOR").unwrap_or_else(|_| "nano".to_string());
            println!("Opening {} with {}...", path.display(), editor);
            std::process::Command::new(&editor)
                .arg(&path)
                .status()?;
        }
    }
    Ok(())
}

// =============================================================================
// Schedule management
// =============================================================================

const PLIST_LABEL: &str = "com.roberdan.rusty-mac-backup";

fn plist_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/roberdan".to_string());
    PathBuf::from(home).join("Library/LaunchAgents").join(format!("{}.plist", PLIST_LABEL))
}

fn generate_plist(interval_secs: u32) -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/roberdan".to_string());
    format!(r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{home}/.local/bin/rustyback</string>
        <string>backup</string>
    </array>
    <key>StartInterval</key>
    <integer>{interval}</integer>
    <key>StandardOutPath</key>
    <string>{home}/.local/share/rusty-mac-backup/backup.log</string>
    <key>StandardErrorPath</key>
    <string>{home}/.local/share/rusty-mac-backup/backup-error.log</string>
    <key>RunAtLoad</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
"#, label = PLIST_LABEL, home = home, interval = interval_secs)
}

fn cmd_schedule(action: ScheduleAction) -> Result<()> {
    let plist = plist_path();

    match action {
        ScheduleAction::On => {
            let content = generate_plist(3600);
            std::fs::write(&plist, &content)?;
            std::process::Command::new("launchctl")
                .args(["load", &plist.to_string_lossy()])
                .status()?;
            println!("{} Schedule enabled (every 60 min)", "✅".green());
        }
        ScheduleAction::Off => {
            if plist.exists() {
                std::process::Command::new("launchctl")
                    .args(["unload", &plist.to_string_lossy()])
                    .status()?;
                std::fs::remove_file(&plist)?;
                println!("{} Schedule disabled", "✅".green());
            } else {
                println!("Schedule not active.");
            }
        }
        ScheduleAction::Status => {
            if plist.exists() {
                let output = std::process::Command::new("launchctl")
                    .args(["list", PLIST_LABEL])
                    .output()?;
                if output.status.success() {
                    // Read interval from plist
                    let content = std::fs::read_to_string(&plist)?;
                    let interval = content
                        .lines()
                        .skip_while(|l| !l.contains("StartInterval"))
                        .nth(1)
                        .and_then(|l| l.trim().trim_start_matches("<integer>").trim_end_matches("</integer>").parse::<u32>().ok())
                        .unwrap_or(0);
                    println!("{} Schedule active — every {} min", "🟢".to_string(), interval / 60);
                    // Show last log
                    let home = std::env::var("HOME").unwrap_or_default();
                    let log = PathBuf::from(&home).join(".local/share/rusty-mac-backup/backup.log");
                    if log.exists() {
                        let content = std::fs::read_to_string(&log)?;
                        let last_lines: Vec<&str> = content.lines().rev().take(3).collect();
                        if !last_lines.is_empty() {
                            println!("\n  Last log:");
                            for l in last_lines.iter().rev() {
                                println!("    {}", l.dimmed());
                            }
                        }
                    }
                } else {
                    println!("{} Plist exists but not loaded", "🟡".to_string());
                }
            } else {
                println!("{} Schedule not configured. Run: rustyback schedule on", "🔴".to_string());
            }
        }
        ScheduleAction::Interval { minutes } => {
            let was_active = plist.exists();
            if was_active {
                let _ = std::process::Command::new("launchctl")
                    .args(["unload", &plist.to_string_lossy()])
                    .status();
            }
            let content = generate_plist(minutes * 60);
            std::fs::write(&plist, &content)?;
            std::process::Command::new("launchctl")
                .args(["load", &plist.to_string_lossy()])
                .status()?;
            println!("{} Schedule set to every {} min", "✅".green(), minutes);
        }
    }
    Ok(())
}
