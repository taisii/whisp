use crate::error::{AppError, AppResult};
use chrono::{Datelike, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Clone)]
pub struct SttUsage {
    pub duration_seconds: f64,
}

#[derive(Debug, Clone)]
pub struct LlmUsage {
    pub model: String,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DailyUsage {
    pub date: String,
    pub deepgram_seconds: f64,
    pub deepgram_requests: u32,
    pub gemini_prompt_tokens: u32,
    pub gemini_completion_tokens: u32,
    pub gemini_requests: u32,
    pub openai_prompt_tokens: u32,
    pub openai_completion_tokens: u32,
    pub openai_requests: u32,
}

impl DailyUsage {
    fn new(date: NaiveDate) -> Self {
        Self {
            date: date.format("%Y-%m-%d").to_string(),
            ..Default::default()
        }
    }

    fn add_stt(&mut self, usage: &SttUsage) {
        self.deepgram_seconds += usage.duration_seconds;
        self.deepgram_requests += 1;
    }

    fn add_llm(&mut self, usage: &LlmUsage) {
        if usage.model.contains("gemini") {
            self.gemini_prompt_tokens += usage.prompt_tokens;
            self.gemini_completion_tokens += usage.completion_tokens;
            self.gemini_requests += 1;
        } else {
            self.openai_prompt_tokens += usage.prompt_tokens;
            self.openai_completion_tokens += usage.completion_tokens;
            self.openai_requests += 1;
        }
    }

    fn merge(&mut self, other: &DailyUsage) {
        self.deepgram_seconds += other.deepgram_seconds;
        self.deepgram_requests += other.deepgram_requests;
        self.gemini_prompt_tokens += other.gemini_prompt_tokens;
        self.gemini_completion_tokens += other.gemini_completion_tokens;
        self.gemini_requests += other.gemini_requests;
        self.openai_prompt_tokens += other.openai_prompt_tokens;
        self.openai_completion_tokens += other.openai_completion_tokens;
        self.openai_requests += other.openai_requests;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct UsageData {
    days: Vec<DailyUsage>,
}

pub struct UsageManager {
    path: PathBuf,
    data: Mutex<UsageData>,
}

impl UsageManager {
    pub fn new() -> AppResult<Self> {
        let base = std::env::var("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(".config"))
            .map_err(|_| AppError::ConfigDirMissing)?;
        let path = base.join("whisp").join("usage.json");

        let data = if path.exists() {
            let content = fs::read_to_string(&path).unwrap_or_default();
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            UsageData::default()
        };

        Ok(Self {
            path,
            data: Mutex::new(data),
        })
    }

    pub fn record_usage(&self, stt: Option<SttUsage>, llm: Option<LlmUsage>) {
        let today = Local::now().date_naive();
        let today_str = today.format("%Y-%m-%d").to_string();

        let mut data = self.data.lock().unwrap();

        let daily = data
            .days
            .iter_mut()
            .find(|d| d.date == today_str);

        if let Some(daily) = daily {
            if let Some(ref stt_usage) = stt {
                daily.add_stt(stt_usage);
            }
            if let Some(ref llm_usage) = llm {
                daily.add_llm(llm_usage);
            }
        } else {
            let mut new_daily = DailyUsage::new(today);
            if let Some(ref stt_usage) = stt {
                new_daily.add_stt(stt_usage);
            }
            if let Some(ref llm_usage) = llm {
                new_daily.add_llm(llm_usage);
            }
            data.days.push(new_daily);
        }

        if let Err(e) = self.save_internal(&data) {
            eprintln!("Failed to save usage data: {e}");
        }
    }

    fn save_internal(&self, data: &UsageData) -> AppResult<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(data)
            .map_err(|e| AppError::Other(format!("JSON serialize error: {e}")))?;
        fs::write(&self.path, json)?;
        Ok(())
    }

    pub fn get_today(&self) -> DailyUsage {
        let today = Local::now().date_naive();
        let today_str = today.format("%Y-%m-%d").to_string();

        let data = self.data.lock().unwrap();
        data.days
            .iter()
            .find(|d| d.date == today_str)
            .cloned()
            .unwrap_or_else(|| DailyUsage::new(today))
    }

    pub fn get_month(&self, year: i32, month: u32) -> DailyUsage {
        let data = self.data.lock().unwrap();

        let mut total = DailyUsage {
            date: format!("{year}-{month:02}"),
            ..Default::default()
        };

        for daily in &data.days {
            if let Ok(date) = NaiveDate::parse_from_str(&daily.date, "%Y-%m-%d") {
                if date.year() == year && date.month() == month {
                    total.merge(daily);
                }
            }
        }

        total
    }

    pub fn get_current_month(&self) -> DailyUsage {
        let now = Local::now();
        self.get_month(now.year(), now.month())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn create_test_manager(path: PathBuf) -> UsageManager {
        UsageManager {
            path,
            data: Mutex::new(UsageData::default()),
        }
    }

    #[test]
    fn record_stt_usage() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("usage.json");
        let manager = create_test_manager(path);

        manager.record_usage(
            Some(SttUsage {
                duration_seconds: 10.5,
            }),
            None,
        );

        let today = manager.get_today();
        assert!((today.deepgram_seconds - 10.5).abs() < 0.001);
        assert_eq!(today.deepgram_requests, 1);
    }

    #[test]
    fn record_llm_usage_gemini() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("usage.json");
        let manager = create_test_manager(path);

        manager.record_usage(
            None,
            Some(LlmUsage {
                model: "gemini-2.5-flash-lite".to_string(),
                prompt_tokens: 100,
                completion_tokens: 50,
            }),
        );

        let today = manager.get_today();
        assert_eq!(today.gemini_prompt_tokens, 100);
        assert_eq!(today.gemini_completion_tokens, 50);
        assert_eq!(today.gemini_requests, 1);
        assert_eq!(today.openai_requests, 0);
    }

    #[test]
    fn record_llm_usage_openai() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("usage.json");
        let manager = create_test_manager(path);

        manager.record_usage(
            None,
            Some(LlmUsage {
                model: "gpt-4o-mini".to_string(),
                prompt_tokens: 200,
                completion_tokens: 100,
            }),
        );

        let today = manager.get_today();
        assert_eq!(today.openai_prompt_tokens, 200);
        assert_eq!(today.openai_completion_tokens, 100);
        assert_eq!(today.openai_requests, 1);
        assert_eq!(today.gemini_requests, 0);
    }

    #[test]
    fn record_both_stt_and_llm() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("usage.json");
        let manager = create_test_manager(path);

        manager.record_usage(
            Some(SttUsage {
                duration_seconds: 5.0,
            }),
            Some(LlmUsage {
                model: "gemini-2.5-flash-lite".to_string(),
                prompt_tokens: 50,
                completion_tokens: 25,
            }),
        );

        let today = manager.get_today();
        assert!((today.deepgram_seconds - 5.0).abs() < 0.001);
        assert_eq!(today.deepgram_requests, 1);
        assert_eq!(today.gemini_prompt_tokens, 50);
        assert_eq!(today.gemini_completion_tokens, 25);
        assert_eq!(today.gemini_requests, 1);
    }

    #[test]
    fn multiple_records_accumulate() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("usage.json");
        let manager = create_test_manager(path);

        manager.record_usage(
            Some(SttUsage {
                duration_seconds: 10.0,
            }),
            None,
        );
        manager.record_usage(
            Some(SttUsage {
                duration_seconds: 5.0,
            }),
            None,
        );

        let today = manager.get_today();
        assert!((today.deepgram_seconds - 15.0).abs() < 0.001);
        assert_eq!(today.deepgram_requests, 2);
    }
}
