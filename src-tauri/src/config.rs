use crate::error::{AppError, AppResult};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct ApiKeys {
    pub deepgram: String,
    pub gemini: String,
    pub openai: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordingMode {
    #[default]
    Toggle,
    PushToTalk,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum LlmModel {
    #[serde(rename = "gemini-2.5-flash-lite")]
    #[default]
    Gemini25FlashLite,
    #[serde(rename = "gemini-2.5-flash-lite-audio")]
    Gemini25FlashLiteAudio,
    #[serde(rename = "gpt-4o-mini")]
    Gpt4oMini,
    #[serde(rename = "gpt-5-nano")]
    Gpt5Nano,
}

impl LlmModel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gemini25FlashLite => "gemini-2.5-flash-lite",
            Self::Gemini25FlashLiteAudio => "gemini-2.5-flash-lite",
            Self::Gpt4oMini => "gpt-4o-mini",
            Self::Gpt5Nano => "gpt-5-nano",
        }
    }

    pub fn uses_direct_audio(self) -> bool {
        matches!(self, Self::Gemini25FlashLiteAudio)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct AppPromptRule {
    pub app_name: String,
    pub template: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct ContextConfig {
    pub accessibility_enabled: bool,
    pub vision_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct BillingSettings {
    pub deepgram_enabled: bool,
    pub deepgram_project_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct Config {
    pub api_keys: ApiKeys,
    pub shortcut: String,
    pub input_language: String,
    pub recording_mode: RecordingMode,
    pub known_apps: Vec<String>,
    pub app_prompt_rules: Vec<AppPromptRule>,
    pub llm_model: LlmModel,
    pub context: ContextConfig,
    pub billing: BillingSettings,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            api_keys: ApiKeys {
                deepgram: String::new(),
                gemini: String::new(),
                openai: String::new(),
            },
            shortcut: "Cmd+J".to_string(),
            input_language: "ja".to_string(),
            recording_mode: RecordingMode::Toggle,
            known_apps: Vec::new(),
            app_prompt_rules: Vec::new(),
            llm_model: LlmModel::Gemini25FlashLite,
            context: ContextConfig {
                accessibility_enabled: true,
                vision_enabled: true,
            },
            billing: BillingSettings::default(),
        }
    }
}

pub struct ConfigManager {
    path: PathBuf,
}

impl ConfigManager {
    pub fn new() -> AppResult<Self> {
        let base = std::env::var("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(".config"))
            .map_err(|_| AppError::ConfigDirMissing)?;
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
                openai: "oa".to_string(),
            },
            shortcut: "Option+Space".to_string(),
            input_language: "ja".to_string(),
            recording_mode: RecordingMode::PushToTalk,
            known_apps: vec!["Slack".to_string(), "VSCode".to_string()],
            app_prompt_rules: vec![AppPromptRule {
                app_name: "Slack".to_string(),
                template: "入力: {STT結果}".to_string(),
            }],
            llm_model: LlmModel::Gpt5Nano,
            context: ContextConfig {
                accessibility_enabled: false,
                vision_enabled: true,
            },
            billing: BillingSettings {
                deepgram_enabled: true,
                deepgram_project_id: "project-123".to_string(),
            },
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
