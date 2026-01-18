use crate::config::{AppPromptRule, LlmModel};
use crate::error::{AppError, AppResult};
use base64::Engine as _;
use serde::{Deserialize, Serialize};

const DEFAULT_PROMPT_TEMPLATE: &str = "以下の音声認識結果を修正してください。修正後のテキストのみを出力してください。\n\n修正ルール:\n1. フィラー（えーと、あのー、えー、なんか、こう、まあ、ちょっと）を除去\n2. 技術用語の誤認識を修正（例: \"リアクト\"→\"React\", \"ユーズステート\"→\"useState\"）\n3. 句読点を適切に追加\n4. 出力は{言語}にしてください\n\n入力: {STT結果}";

#[derive(Debug, Serialize)]
struct GeminiRequest {
    contents: Vec<GeminiContent>,
}

#[derive(Debug, Serialize)]
struct GeminiContent {
    role: String,
    parts: Vec<GeminiPart>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum GeminiPart {
    Text { text: String },
    InlineData { inline_data: GeminiInlineData },
}

#[derive(Debug, Serialize)]
struct GeminiInlineData {
    mime_type: String,
    data: String,
}

#[derive(Debug, Deserialize)]
struct GeminiResponse {
    candidates: Vec<GeminiCandidate>,
}

#[derive(Debug, Deserialize)]
struct GeminiCandidate {
    content: GeminiContentResponse,
}

#[derive(Debug, Deserialize)]
struct GeminiContentResponse {
    parts: Vec<GeminiPartResponse>,
}

#[derive(Debug, Deserialize)]
struct GeminiPartResponse {
    text: String,
}

#[derive(Debug, Serialize)]
struct OpenAiRequest {
    model: String,
    messages: Vec<OpenAiMessage>,
}

#[derive(Debug, Serialize)]
struct OpenAiMessage {
    role: String,
    content: String,
}

#[derive(Debug, Deserialize)]
struct OpenAiResponse {
    choices: Vec<OpenAiChoice>,
}

#[derive(Debug, Deserialize)]
struct OpenAiChoice {
    message: OpenAiMessageResponse,
}

#[derive(Debug, Deserialize)]
struct OpenAiMessageResponse {
    content: String,
}

fn language_label(language_hint: &str) -> String {
    match language_hint {
        "ja" => "日本語".to_string(),
        "en" => "英語".to_string(),
        _ => "自動判定（日本語/英語）".to_string(),
    }
}

fn apply_template(template: &str, stt_result: &str, language_hint: &str) -> String {
    let label = language_label(language_hint);
    let mut prompt = template
        .replace("{言語}", &label)
        .replace("{STT結果}", stt_result);
    if !template.contains("{STT結果}") {
        prompt.push_str("\n\n入力: ");
        prompt.push_str(stt_result);
    }
    prompt
}

fn resolve_app_template<'a>(
    app_name: Option<&str>,
    rules: &'a [AppPromptRule],
) -> Option<&'a str> {
    let app_name = app_name?.trim();
    if app_name.is_empty() {
        return None;
    }
    for rule in rules {
        if rule.app_name.trim() == app_name {
            let template = rule.template.trim();
            return if template.is_empty() { None } else { Some(template) };
        }
    }
    None
}

pub fn build_prompt(
    stt_result: &str,
    language_hint: &str,
    app_name: Option<&str>,
    app_prompt_rules: &[AppPromptRule],
) -> String {
    let template = resolve_app_template(app_name, app_prompt_rules)
        .unwrap_or(DEFAULT_PROMPT_TEMPLATE);
    apply_template(template, stt_result, language_hint)
}

const AUDIO_TRANSCRIBE_INSTRUCTION: &str = "次の音声を文字起こしし、フィラーを除去して整形してください。修正後のテキストのみを出力してください。";

pub async fn post_process(
    model: LlmModel,
    api_key: &str,
    stt_result: &str,
    language_hint: &str,
    app_name: Option<&str>,
    app_prompt_rules: &[AppPromptRule],
) -> AppResult<String> {
    let prompt = build_prompt(
        stt_result,
        language_hint,
        app_name,
        app_prompt_rules,
    );
    match model {
        LlmModel::Gemini25FlashLite => post_process_gemini(api_key, &prompt).await,
        LlmModel::Gpt4oMini | LlmModel::Gpt5Nano => {
            post_process_openai(api_key, model, &prompt).await
        }
    }
}

async fn post_process_gemini(api_key: &str, prompt: &str) -> AppResult<String> {
    let req = GeminiRequest {
        contents: vec![GeminiContent {
            role: "user".to_string(),
            parts: vec![GeminiPart::Text {
                text: prompt.to_string(),
            }],
        }],
    };

    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={api_key}",
        LlmModel::Gemini25FlashLite.as_str()
    );

    let client = reqwest::Client::new();
    let response = client.post(url).json(&req).send().await?;
    let status = response.status();
    let body = response.text().await?;

    if !status.is_success() {
        return Err(AppError::Other(format!(
            "Gemini API error: {status} {body}"
        )));
    }

    let parsed: GeminiResponse = serde_json::from_str(&body)
        .map_err(|e| AppError::Other(format!("Gemini response parse error: {e}")))?;
    let text = parsed
        .candidates
        .first()
        .and_then(|c| c.content.parts.first())
        .map(|p| p.text.trim().to_string())
        .unwrap_or_default();
    Ok(text)
}

pub async fn transcribe_audio_gemini(
    api_key: &str,
    audio_bytes: &[u8],
    mime_type: &str,
) -> AppResult<String> {
    let inline_data = GeminiInlineData {
        mime_type: mime_type.to_string(),
        data: base64::engine::general_purpose::STANDARD.encode(audio_bytes),
    };
    let req = GeminiRequest {
        contents: vec![GeminiContent {
            role: "user".to_string(),
            parts: vec![
                GeminiPart::Text {
                    text: AUDIO_TRANSCRIBE_INSTRUCTION.to_string(),
                },
                GeminiPart::InlineData { inline_data },
            ],
        }],
    };
    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={api_key}",
        LlmModel::Gemini25FlashLite.as_str()
    );
    let client = reqwest::Client::new();
    let response = client.post(url).json(&req).send().await?;
    let status = response.status();
    let body = response.text().await?;

    if !status.is_success() {
        return Err(AppError::Other(format!(
            "Gemini API error: {status} {body}"
        )));
    }

    let parsed: GeminiResponse = serde_json::from_str(&body)
        .map_err(|e| AppError::Other(format!("Gemini response parse error: {e}")))?;
    let text = parsed
        .candidates
        .first()
        .and_then(|c| c.content.parts.first())
        .map(|p| p.text.trim().to_string())
        .unwrap_or_default();
    Ok(text)
}

async fn post_process_openai(
    api_key: &str,
    model: LlmModel,
    prompt: &str,
) -> AppResult<String> {
    let req = OpenAiRequest {
        model: model.as_str().to_string(),
        messages: vec![OpenAiMessage {
            role: "user".to_string(),
            content: prompt.to_string(),
        }],
    };

    let client = reqwest::Client::new();
    let response = client
        .post("https://api.openai.com/v1/chat/completions")
        .bearer_auth(api_key)
        .json(&req)
        .send()
        .await?;
    let status = response.status();
    let body = response.text().await?;

    if !status.is_success() {
        return Err(AppError::Other(format!(
            "OpenAI API error: {status} {body}"
        )));
    }

    let parsed: OpenAiResponse = serde_json::from_str(&body)
        .map_err(|e| AppError::Other(format!("OpenAI response parse error: {e}")))?;
    let text = parsed
        .choices
        .first()
        .map(|c| c.message.content.trim().to_string())
        .unwrap_or_default();
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_includes_input() {
        let prompt = build_prompt("テストです", "ja", None, &[]);
        assert!(prompt.contains("入力: テストです"));
    }

    #[test]
    fn app_prompt_replaces_placeholders() {
        let prompt = build_prompt(
            "こんにちは",
            "en",
            Some("Slack"),
            &[AppPromptRule {
                app_name: "Slack".to_string(),
                template: "出力は{言語}。入力={STT結果}".to_string(),
            }],
        );
        assert!(prompt.contains("出力は英語。入力=こんにちは"));
    }

    #[test]
    fn app_prompt_appends_input_when_missing() {
        let prompt = build_prompt(
            "テスト",
            "ja",
            Some("Slack"),
            &[AppPromptRule {
                app_name: "Slack".to_string(),
                template: "指示だけ".to_string(),
            }],
        );
        assert!(prompt.contains("指示だけ"));
        assert!(prompt.contains("入力: テスト"));
    }

    #[test]
    fn parse_response() {
        let json = r#"{
            "candidates": [
                { "content": { "parts": [ { "text": "整形済み" } ] } }
            ]
        }"#;
        let parsed: GeminiResponse = serde_json::from_str(json).expect("parse");
        let text = parsed.candidates[0].content.parts[0].text.clone();
        assert_eq!(text, "整形済み");
    }

    #[test]
    fn parse_openai_response() {
        let json = r#"{
            "choices": [
                { "message": { "content": "整形済み" } }
            ]
        }"#;
        let parsed: OpenAiResponse = serde_json::from_str(json).expect("parse");
        let text = parsed.choices[0].message.content.clone();
        assert_eq!(text, "整形済み");
    }
}
