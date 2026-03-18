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
        println!("   Run `rustyback config edit` to modify it.");
        println!("   Run `rustyback init --force` to reconfigure from scratch.");
        return Ok(());
    }

    let total_steps = 6;
    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/roberdan".to_string());
    let terminal_name = std::env::var("TERM_PROGRAM").unwrap_or_else(|_| "Terminal".to_string());

    println!();
    println!("{}", "🦀 RustyMacBackup — First Time Setup".bold().cyan());
    println!("{}", "━".repeat(50).dimmed());
    println!();

    // =========================================================================
    // Step 1: Check Full Disk Access
    // =========================================================================
    println!("{} Checking Full Disk Access...", step_label(1, total_steps));
    
    // Try reading a TCC-protected path to verify FDA
    let fda_ok = std::fs::read_dir(format!("{}/Library/Mail", home)).is_ok() 
        || std::fs::read_dir(format!("{}/Library/Messages", home)).is_ok()
        || std::fs::metadata(format!("{}/Library/Safari", home)).is_ok();

    if !fda_ok {
        println!();
        println!("  {} {} needs Full Disk Access to back up your data.", "⚠".yellow().bold(), terminal_name.bold());
        println!();
        println!("  How to enable:");
        println!("  1. Open {} → {} → {} → {}",
            "System Settings".bold(),
            "Privacy & Security".bold(),
            "Full Disk Access".bold(),
            terminal_name.bold()
        );
        println!("  2. Toggle {} {}", terminal_name.bold(), "ON".green().bold());
        println!("  3. Restart {} and run {} again", terminal_name.bold(), "rustyback init".cyan());
        println!();
        anyhow::bail!("Full Disk Access required. See instructions above.");
    }
    println!("  {} Full Disk Access granted", "✅".green());

    // =========================================================================
    // Step 2: Discover disks
    // =========================================================================
    println!("{} Scanning for backup disks...", step_label(2, total_steps));
    let volumes = discover_volumes()?;

    if volumes.is_empty() {
        println!();
        println!("  {} No external disks found!", "❌".red());
        println!();
        println!("  Connect an external drive and run {} again.", "rustyback init".cyan());
        anyhow::bail!("No backup disk available.");
    }

    // Show volume menu
    println!();
    for (i, (name, _path, size, encrypted)) in volumes.iter().enumerate() {
        let lock = if *encrypted { 
            format!("{}", "🔒 encrypted".green())
        } else { 
            format!("{}", "⚠ NOT encrypted".red().bold())
        };
        println!("  {}. {} — {} free — {}", 
            (i + 1).to_string().cyan().bold(), 
            name.bold(), 
            format_bytes(*size),
            lock,
        );
    }
    println!();

    // Ask user to pick
    let choice = if volumes.len() == 1 {
        println!("  Using: {}", volumes[0].0.bold());
        0
    } else {
        print!("  Select disk [1-{}]: ", volumes.len());
        std::io::Write::flush(&mut std::io::stdout())?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        let num: usize = input.trim().parse().unwrap_or(0);
        if num < 1 || num > volumes.len() {
            anyhow::bail!("Invalid choice. Run `rustyback init` again.");
        }
        num - 1
    };

    let (vol_name, vol_path, _, encrypted) = &volumes[choice];

    // =========================================================================
    // Step 3: Check encryption
    // =========================================================================
    println!("{} Verifying disk encryption...", step_label(3, total_steps));

    if !encrypted {
        println!();
        println!("  {} {} is NOT encrypted!", "🔒".to_string(), vol_name.bold().red());
        println!();
        println!("  RustyMacBackup requires encryption to protect your data.");
        println!();
        println!("  How to encrypt:");
        println!("  1. Open {}", "Finder".bold());
        println!("  2. Right-click {} in the sidebar", vol_name.bold());
        println!("  3. Select {}", "Encrypt…".bold());
        println!("  4. Choose a strong password and wait for encryption to complete");
        println!("  5. Run {} again", "rustyback init".cyan());
        println!();
        anyhow::bail!("Disk encryption required. See instructions above.");
    }
    println!("  {} {} is encrypted (FileVault)", "✅".green(), vol_name);

    let backup_dir = vol_path.join("RustyMacBackup");

    // =========================================================================
    // Step 4: Set up backup folder and permissions
    // =========================================================================
    println!("{} Setting up backup folder...", step_label(4, total_steps));
    ensure_writable_dir(&backup_dir)?;
    println!("  {} {}", "✅".green(), backup_dir.display());

    // =========================================================================
    // Step 5: Generate config
    // =========================================================================
    println!("{} Creating configuration...", step_label(5, total_steps));

    let config_content = generate_default_config(&home, &backup_dir);
    if let Some(parent) = config_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&config_path, &config_content)?;
    println!("  {} {}", "✅".green(), config_path.display().to_string().dimmed());

    // =========================================================================
    // Step 6: Summary and next steps
    // =========================================================================
    println!("{} Setup complete!", step_label(6, total_steps));

    println!();
    println!("{}", "━".repeat(50).dimmed());
    println!("{}", "🦀 RustyMacBackup is ready!".bold().green());
    println!("{}", "━".repeat(50).dimmed());
    println!();
    println!("  {} {}", "Source:".bold(), home);
    println!("  {} /Applications, /opt/homebrew, /etc, /Library", "System:".bold());
    println!("  {} {}", "Dest:".bold(), backup_dir.display().to_string().green());
    println!("  {} config.toml", "Config:".bold());
    println!();
    println!("{}", "What's next:".bold());
    println!("  {} {} {}", "1.".cyan(), "rustyback backup".bold(), "— run your first backup now");
    println!("  {} {} {}", "2.".cyan(), "rustyback schedule on".bold(), "— enable automatic hourly backups");
    println!("  {} {} {}", "3.".cyan(), "rustyback config excludes".bold(), "— review what's excluded");
    println!();
    println!("  For automatic backups, also add {} to Full Disk Access:",
        "rustyback".bold());
    println!("  {}", format!("{}/.local/bin/rustyback", home).dimmed());
    println!();

    // Offer to run first backup now
    print!("  Run first backup now? [Y/n]: ");
    std::io::Write::flush(&mut std::io::stdout())?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let answer = input.trim().to_lowercase();
    if answer.is_empty() || answer == "y" || answer == "yes" {
        println!();
        drop(input);
        let config = config::Config::load(&config_path)?;
        let start = std::time::Instant::now();
        let stats = backup::run_backup(&config)?;
        let elapsed = start.elapsed();

        println!();
        println!("{}", "━".repeat(50).dimmed());
        println!("{}", "First backup complete!".bold().green());
        println!("  {} files hard-linked", stats.files_hardlinked.to_string().cyan());
        println!("  {} files copied", stats.files_copied.to_string().yellow());
        println!("  {} total", format_bytes(stats.bytes_copied));
        println!("  ⏱  {:.1}s", elapsed.as_secs_f64());
        if !stats.errors.is_empty() {
            println!("  {} errors (permission denied on protected files — normal)", stats.errors.len());
        }
    }

    Ok(())
}

fn step_label(step: u32, total: u32) -> String {
    format!("\n  {} ", format!("[{}/{}]", step, total).cyan().bold())
}

fn discover_volumes() -> Result<Vec<(String, PathBuf, u64, bool)>> {
    let mut volumes = Vec::new();
    let volumes_dir = std::path::Path::new("/Volumes");

    if !volumes_dir.exists() {
        return Ok(volumes);
    }

    for entry in std::fs::read_dir(volumes_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();

        // Skip the boot volume
        if name == "Macintosh HD" || name == "Macintosh HD - Data" {
            continue;
        }

        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        // Get free space
        let free = get_volume_free_space(&path).unwrap_or(0);
        if free > 0 {
            let encrypted = is_volume_encrypted(&path);
            volumes.push((name, path, free, encrypted));
        }
    }

    // Sort by name
    volumes.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(volumes)
}

/// Check if a volume is encrypted (APFS encrypted or FileVault/CoreStorage)
fn is_volume_encrypted(path: &std::path::Path) -> bool {
    let output = std::process::Command::new("diskutil")
        .args(["info", &path.to_string_lossy()])
        .output();

    match output {
        Ok(out) => {
            let info = String::from_utf8_lossy(&out.stdout);
            // Check for APFS encryption or FileVault
            info.lines().any(|line| {
                let line = line.trim();
                (line.starts_with("FileVault:") && line.contains("Yes"))
                    || (line.starts_with("Encrypted:") && line.contains("Yes"))
                    || (line.contains("Encryption Type:") && !line.contains("None"))
            })
        }
        Err(_) => false,
    }
}

/// Verify the destination volume is encrypted; bail if not
fn require_encrypted_volume(dest: &std::path::Path) -> Result<()> {
    // Find the volume mount point (e.g. /Volumes/RoberdanBCK 1)
    let volume_path = if dest.starts_with("/Volumes") {
        // Extract /Volumes/<name>
        let components: Vec<_> = dest.components().collect();
        if components.len() >= 3 {
            PathBuf::from("/Volumes").join(components[2].as_os_str())
        } else {
            dest.to_path_buf()
        }
    } else {
        dest.to_path_buf()
    };

    if !is_volume_encrypted(&volume_path) {
        anyhow::bail!(
            "🔒 Security: backup destination is NOT encrypted!\n\n\
             Volume: {}\n\n\
             RustyMacBackup requires an encrypted disk to protect your data.\n\
             To encrypt this disk:\n\
             1. Open Finder → right-click the disk → Encrypt\n\
             2. Set a strong password\n\
             3. Wait for encryption to complete\n\
             4. Run `rustyback init` again",
            volume_path.display()
        );
    }
    Ok(())
}

fn get_volume_free_space(path: &std::path::Path) -> Result<u64> {
    use std::ffi::CString;
    use std::mem::MaybeUninit;
    let c_path = CString::new(path.to_string_lossy().as_bytes())?;
    let mut stat: MaybeUninit<libc::statfs> = MaybeUninit::uninit();
    let result = unsafe { libc::statfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if result != 0 {
        anyhow::bail!("statfs failed");
    }
    let stat = unsafe { stat.assume_init() };
    Ok(stat.f_bavail as u64 * stat.f_bsize as u64)
}

fn ensure_writable_dir(path: &std::path::Path) -> Result<()> {
    // Try creating the directory directly first
    match std::fs::create_dir_all(path) {
        Ok(_) => {
            // Test write access
            let test_file = path.join(".rmb-write-test");
            match std::fs::write(&test_file, "test") {
                Ok(_) => {
                    let _ = std::fs::remove_file(&test_file);
                    return Ok(());
                }
                Err(_) => {} // Fall through to sudo
            }
        }
        Err(_) => {} // Fall through to sudo
    }

    // Need elevated permissions
    println!();
    println!("  {} This disk requires admin permissions for the first setup.", "🔑".to_string());
    println!("  You'll be asked for your password once. This won't be needed again.");
    println!();

    // Create dir with sudo (works on APFS regardless of Owners setting)
    std::process::Command::new("sudo")
        .args(["mkdir", "-p", &path.to_string_lossy()])
        .status()?;

    // Set permissions so our user can write without sudo from now on
    // Use chmod instead of chown — works even when Owners is disabled on APFS
    std::process::Command::new("sudo")
        .args(["chmod", "777", &path.to_string_lossy()])
        .status()?;

    // Also try to enable ownership on the volume (may fail silently, that's OK)
    if let Some(parent) = path.parent() {
        let _ = std::process::Command::new("sudo")
            .args(["diskutil", "enableOwnership", &parent.to_string_lossy()])
            .output(); // ignore errors — not all volumes support this
    }

    // Verify
    let test_file = path.join(".rmb-write-test");
    std::fs::write(&test_file, "test")?;
    std::fs::remove_file(&test_file)?;

    println!("  {} Permissions set", "✅".green());
    Ok(())
}

fn generate_default_config(home: &str, backup_dir: &std::path::Path) -> String {
    format!(r#"[source]
path = "{home}"
# System paths to include in backup (apps, homebrew, system config)
extra_paths = [
    "/Applications",
    "/opt/homebrew",
    "/usr/local",
    "/etc",
    "/Library",
]

[destination]
path = "{dest}"

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
    "Library/Updates",
    "Library/Developer",

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
"#, home = home, dest = backup_dir.display())
}

fn cmd_backup(config_path: &Option<PathBuf>) -> Result<()> {
    let config = load_config(config_path)?;

    // Check if running on battery — skip if scheduled (non-interactive)
    if is_on_battery() && !atty::is(atty::Stream::Stdout) {
        eprintln!("🔋 On battery power — skipping scheduled backup.");
        return Ok(());
    }
    if is_on_battery() {
        println!("{}", "🔋 Note: running on battery. Backup will use low priority I/O.".yellow());
    }

    // Check if destination disk is connected
    if !config.destination.path.exists() && !config.destination.path.starts_with("/tmp") {
        // Extract volume name for a friendly message
        let vol_name = config.destination.path.components()
            .nth(2)
            .map(|c| c.as_os_str().to_string_lossy().to_string())
            .unwrap_or_else(|| config.destination.path.display().to_string());
        
        if atty::is(atty::Stream::Stdout) {
            anyhow::bail!(
                "💾 Backup disk \"{}\" is not connected.\n   \
                 Connect the disk and try again.",
                vol_name
            );
        } else {
            // Scheduled run — just exit silently
            eprintln!("💾 Backup disk \"{}\" not connected — skipping.", vol_name);
            return Ok(());
        }
    }

    let start = Instant::now();

    println!("{}", "🦀 RustyMacBackup".bold().cyan());
    for (i, src) in config.source.all_paths().iter().enumerate() {
        if i == 0 {
            println!("   Source: {}", src.display());
        } else {
            println!("          {}", src.display());
        }
    }
    println!("   Dest:   {}", config.destination.path.display());
    println!();

    // Ensure destination is writable before starting
    ensure_writable_dir(&config.destination.path)?;

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

    out.push_str(&format!("[source]\npath = {:?}\n", config.source.path.to_string_lossy()));
    if !config.source.extra_paths.is_empty() {
        out.push_str("extra_paths = [\n");
        for p in &config.source.extra_paths {
            out.push_str(&format!("    {:?},\n", p.to_string_lossy()));
        }
        out.push_str("]\n");
    }
    out.push('\n');

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

// =============================================================================
// Power management
// =============================================================================

/// Check if Mac is running on battery (not plugged in)
fn is_on_battery() -> bool {
    let output = std::process::Command::new("pmset")
        .args(["-g", "batt"])
        .output();
    match output {
        Ok(out) => {
            let info = String::from_utf8_lossy(&out.stdout);
            info.contains("'Battery Power'")
        }
        Err(_) => false, // Can't determine — assume plugged in
    }
}
