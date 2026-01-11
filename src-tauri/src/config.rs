use crate::error::{AppError, AppResult};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct ApiKeys {
    pub deepgram: String,
    pub gemini: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Config {
    pub api_keys: ApiKeys,
    pub shortcut: String,
    pub auto_paste: bool,
    pub input_language: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            api_keys: ApiKeys {
                deepgram: String::new(),
                gemini: String::new(),
            },
            shortcut: "Cmd+J".to_string(),
            auto_paste: true,
            input_language: "ja".to_string(),
        }
    }
}

pub struct ConfigManager {
    path: PathBuf,
}

impl ConfigManager {
    pub fn new() -> AppResult<Self> {
        let base = dirs::config_dir().ok_or(AppError::ConfigDirMissing)?;
        Ok(Self {
            path: base.join("whisp").join("config.toml"),
        })
    }

    #[cfg(test)]
    pub fn with_path(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> AppResult<Config> {
        let content = fs::read_to_string(&self.path)?;
        Ok(toml::from_str(&content)?)
    }

    pub fn save(&self, config: &Config) -> AppResult<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let data = toml::to_string_pretty(config)?;
        fs::write(&self.path, data)?;
        Ok(())
    }

    pub fn load_or_create(&self) -> AppResult<Config> {
        match self.load() {
            Ok(config) => Ok(config),
            Err(_) => {
                let config = Config::default();
                self.save(&config)?;
                Ok(config)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn config_roundtrip() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("config.toml");
        let manager = ConfigManager::with_path(path);

        let config = Config {
            api_keys: ApiKeys {
                deepgram: "dg".to_string(),
                gemini: "gm".to_string(),
            },
            shortcut: "Option+Space".to_string(),
            auto_paste: false,
            input_language: "ja".to_string(),
        };

        manager.save(&config).expect("save");
        let loaded = manager.load().expect("load");
        assert_eq!(loaded, config);
    }

    #[test]
    fn load_or_create_creates_default() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("config.toml");
        let manager = ConfigManager::with_path(path.clone());

        let config = manager.load_or_create().expect("load_or_create");
        assert_eq!(config, Config::default());
        assert!(path.exists());
    }
}
