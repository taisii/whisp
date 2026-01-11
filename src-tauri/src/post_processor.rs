use crate::error::{AppError, AppResult};
use serde::{Deserialize, Serialize};

const GEMINI_MODEL: &str = "gemini-2.5-flash-lite";

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
struct GeminiPart {
    text: String,
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

pub fn build_prompt(stt_result: &str, language_hint: &str) -> String {
    let lang_rule = match language_hint {
        "ja" => "4. 出力は日本語にしてください",
        "en" => "4. 出力は英語にしてください",
        _ => "4. 言語は自動判定（日本語/英語）",
    };

    format!(
        "以下の音声認識結果を修正してください。修正後のテキストのみを出力してください。\n\n修正ルール:\n1. フィラー（えーと、あのー、えー、なんか、こう、まあ、ちょっと）を除去\n2. 技術用語の誤認識を修正（例: \"リアクト\"→\"React\", \"ユーズステート\"→\"useState\"）\n3. 句読点を適切に追加\n{lang_rule}\n\n入力: {stt_result}"
    )
}

pub async fn post_process(
    api_key: &str,
    stt_result: &str,
    language_hint: &str,
) -> AppResult<String> {
    let prompt = build_prompt(stt_result, language_hint);
    let req = GeminiRequest {
        contents: vec![GeminiContent {
            role: "user".to_string(),
            parts: vec![GeminiPart { text: prompt }],
        }],
    };

    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={api_key}"
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_includes_input() {
        let prompt = build_prompt("テストです", "ja");
        assert!(prompt.contains("入力: テストです"));
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
}
