use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub source: SourceConfig,
    pub destination: DestinationConfig,
    #[serde(default)]
    pub exclude: ExcludeConfig,
    #[serde(default)]
    pub retention: RetentionConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct SourceConfig {
    pub path: PathBuf,
}

#[derive(Debug, Deserialize, Clone)]
pub struct DestinationConfig {
    pub path: PathBuf,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct ExcludeConfig {
    #[serde(default)]
    pub patterns: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RetentionConfig {
    #[serde(default = "default_hourly")]
    pub hourly: u32,
    #[serde(default = "default_daily")]
    pub daily: u32,
    #[serde(default = "default_weekly")]
    pub weekly: u32,
    #[serde(default)]
    pub monthly: u32,
}

impl Default for RetentionConfig {
    fn default() -> Self {
        Self {
            hourly: 24,
            daily: 30,
            weekly: 52,
            monthly: 0,
        }
    }
}

fn default_hourly() -> u32 { 24 }
fn default_daily() -> u32 { 30 }
fn default_weekly() -> u32 { 52 }

impl Config {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let content = fs::read_to_string(path)?;
        let config: Config = toml::from_str(&content)?;
        Ok(config)
    }

    pub fn default_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/roberdan".to_string());
        PathBuf::from(home).join(".config").join("rusty-mac-backup").join("config.toml")
    }
}
