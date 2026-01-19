use crate::error::{AppError, AppResult};
use crate::usage::SttUsage;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::sync::Arc;
use tokio::sync::mpsc::Receiver;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptChunk {
    pub text: String,
    pub is_final: bool,
}

#[derive(Debug, Clone)]
pub struct SttResult {
    pub transcript: String,
    pub usage: Option<SttUsage>,
}

#[derive(Debug, Clone)]
pub enum SttEvent {
    Connected,
    AudioStreamEnded,
    FinalTranscript(String),
    Error(String),
}

pub async fn run_deepgram_stream(
    api_key: &str,
    sample_rate: u32,
    audio_rx: Receiver<Vec<u8>>,
) -> AppResult<SttResult> {
    run_deepgram_stream_with_events(api_key, sample_rate, audio_rx, None, None).await
}

pub async fn run_deepgram_bytes(
    api_key: &str,
    sample_rate: u32,
    audio: Vec<u8>,
    realtime: bool,
    on_event: Option<Arc<dyn Fn(SttEvent) + Send + Sync>>,
    language: Option<String>,
) -> AppResult<SttResult> {
    let (audio_tx, audio_rx) = tokio::sync::mpsc::channel(8);
    let chunk_bytes = ((sample_rate / 10) * 2).max(2) as usize;

    tokio::spawn(async move {
        for chunk in audio.chunks(chunk_bytes) {
            if audio_tx.send(chunk.to_vec()).await.is_err() {
                break;
            }
            if realtime {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
    });

    run_deepgram_stream_with_events(api_key, sample_rate, audio_rx, on_event, language).await
}

pub async fn run_deepgram_stream_with_events(
    api_key: &str,
    sample_rate: u32,
    mut audio_rx: Receiver<Vec<u8>>,
    on_event: Option<Arc<dyn Fn(SttEvent) + Send + Sync>>,
    language: Option<String>,
) -> AppResult<SttResult> {
    let on_event: Arc<dyn Fn(SttEvent) + Send + Sync> =
        on_event.unwrap_or_else(|| Arc::new(|_| {}));
    let mut url = format!("wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate={sample_rate}&channels=1&punctuate=false");
    if let Some(lang) = language {
        url.push_str("&language=");
        url.push_str(&lang);
    }
    let mut request = url.into_client_request()?;
    request.headers_mut().insert(
        "Authorization",
        format!("Token {api_key}").parse().map_err(|e| {
            AppError::Other(format!("invalid auth header: {e}"))
        })?,
    );

    let (ws_stream, _) = tokio_tungstenite::connect_async(request).await?;
    on_event(SttEvent::Connected);
    let (mut ws_write, mut ws_read) = ws_stream.split();

    let on_event_send = on_event.clone();
    let send_task = tokio::spawn(async move {
        while let Some(bytes) = audio_rx.recv().await {
            ws_write.send(Message::Binary(bytes)).await?;
        }
        on_event_send(SttEvent::AudioStreamEnded);
        ws_write.send(Message::Close(None)).await?;
        Ok::<_, tokio_tungstenite::tungstenite::Error>(())
    });

    let on_event_recv = on_event.clone();
    let recv_task = tokio::spawn(async move {
        let mut final_segments: Vec<String> = Vec::new();
        let mut partial = String::new();
        let mut last_duration: f64 = 0.0;
        let mut last_request_id: Option<String> = None;
        while let Some(msg) = ws_read.next().await {
            let msg = msg?;
            if let Message::Text(text) = msg {
                if let Some(parsed) = parse_deepgram_message_with_duration(&text) {
                    if parsed.duration > 0.0 {
                        last_duration = parsed.duration;
                    }
                    if parsed.request_id.is_some() {
                        last_request_id = parsed.request_id.clone();
                    }
                    if parsed.chunk.text.trim().is_empty() {
                        continue;
                    }
                    if parsed.chunk.is_final {
                        on_event_recv(SttEvent::FinalTranscript(parsed.chunk.text.clone()));
                        final_segments.push(parsed.chunk.text);
                        partial.clear();
                    } else {
                        partial = parsed.chunk.text;
                    }
                }
            }
        }

        let mut all = final_segments.join(" ");
        if !partial.trim().is_empty() {
            if !all.is_empty() {
                all.push(' ');
            }
            all.push_str(&partial);
        }
        let usage = if last_duration > 0.0 {
            Some(SttUsage {
                duration_seconds: last_duration,
                request_id: last_request_id,
            })
        } else {
            None
        };
        Ok::<_, tokio_tungstenite::tungstenite::Error>(SttResult {
            transcript: all.trim().to_string(),
            usage,
        })
    });

    let send_result = send_task.await.map_err(|e| AppError::Other(e.to_string()))?;
    if let Err(e) = send_result {
        on_event(SttEvent::Error(e.to_string()));
        return Err(AppError::WebSocket(e.to_string()));
    }

    let recv_result = recv_task.await.map_err(|e| AppError::Other(e.to_string()))?;
    let stt_result = recv_result.map_err(|e| {
        on_event(SttEvent::Error(e.to_string()));
        AppError::WebSocket(e.to_string())
    })?;
    Ok(stt_result)
}

pub fn parse_deepgram_message(text: &str) -> Option<TranscriptChunk> {
    let parsed: DeepgramMessage = serde_json::from_str(text).ok()?;
    let alternative = parsed.channel.alternatives.first()?;
    Some(TranscriptChunk {
        text: alternative.transcript.clone(),
        is_final: parsed.is_final,
    })
}

struct ParsedDeepgramMessage {
    chunk: TranscriptChunk,
    duration: f64,
    request_id: Option<String>,
}

fn parse_deepgram_message_with_duration(text: &str) -> Option<ParsedDeepgramMessage> {
    let parsed: DeepgramMessage = serde_json::from_str(text).ok()?;
    let alternative = parsed.channel.alternatives.first()?;
    let metadata_duration = parsed.metadata.as_ref().map(|m| m.duration).unwrap_or(0.0);
    let duration = if metadata_duration > 0.0 {
        metadata_duration
    } else {
        parsed.duration
    };
    let request_id = parsed
        .metadata
        .and_then(|m| if m.request_id.is_empty() { None } else { Some(m.request_id) });
    Some(ParsedDeepgramMessage {
        chunk: TranscriptChunk {
            text: alternative.transcript.clone(),
            is_final: parsed.is_final,
        },
        duration,
        request_id,
    })
}

#[derive(Debug, Deserialize)]
struct DeepgramMessage {
    channel: DeepgramChannel,
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    duration: f64,
    metadata: Option<DeepgramMetadata>,
}

#[derive(Debug, Deserialize)]
struct DeepgramMetadata {
    #[serde(default)]
    duration: f64,
    #[serde(default)]
    request_id: String,
}

#[derive(Debug, Deserialize)]
struct DeepgramChannel {
    alternatives: Vec<DeepgramAlternative>,
}

#[derive(Debug, Deserialize)]
struct DeepgramAlternative {
    #[serde(default)]
    transcript: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_partial_transcript() {
        let payload = r#"{
            "channel": { "alternatives": [ { "transcript": "hello" } ] },
            "is_final": false
        }"#;
        let chunk = parse_deepgram_message(payload).expect("chunk");
        assert_eq!(
            chunk,
            TranscriptChunk {
                text: "hello".to_string(),
                is_final: false
            }
        );
    }

    #[test]
    fn parse_final_transcript() {
        let payload = r#"{
            "channel": { "alternatives": [ { "transcript": "world" } ] },
            "is_final": true
        }"#;
        let chunk = parse_deepgram_message(payload).expect("chunk");
        assert!(chunk.is_final);
        assert_eq!(chunk.text, "world");
    }

    #[test]
    fn parse_transcript_with_duration() {
        let payload = r#"{
            "channel": { "alternatives": [ { "transcript": "hello" } ] },
            "is_final": true,
            "duration": 5.25
        }"#;
        let parsed = parse_deepgram_message_with_duration(payload).expect("parsed");
        assert!(parsed.chunk.is_final);
        assert_eq!(parsed.chunk.text, "hello");
        assert!((parsed.duration - 5.25).abs() < 0.001);
        assert_eq!(parsed.request_id, None);
    }

    #[test]
    fn parse_transcript_without_duration() {
        let payload = r#"{
            "channel": { "alternatives": [ { "transcript": "test" } ] },
            "is_final": false
        }"#;
        let parsed = parse_deepgram_message_with_duration(payload).expect("parsed");
        assert!(!parsed.chunk.is_final);
        assert!((parsed.duration - 0.0).abs() < 0.001);
        assert_eq!(parsed.request_id, None);
    }

    #[test]
    fn parse_metadata_duration_and_request_id() {
        let payload = r#"{
            "channel": { "alternatives": [ { "transcript": "hello" } ] },
            "is_final": true,
            "metadata": {
                "duration": 3.5,
                "request_id": "abc123"
            }
        }"#;
        let parsed = parse_deepgram_message_with_duration(payload).expect("parsed");
        assert!(parsed.chunk.is_final);
        assert_eq!(parsed.chunk.text, "hello");
        assert!((parsed.duration - 3.5).abs() < 0.001);
        assert_eq!(parsed.request_id.as_deref(), Some("abc123"));
    }
}
