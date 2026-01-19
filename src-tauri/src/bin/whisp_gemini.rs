use std::env;
use std::io::{self, Read};
use std::path::Path;
use whisp_lib::config::LlmModel;

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    let env_api_key = env::var("GEMINI_API_KEY").ok();
    let parsed = parse_args(&args, env_api_key)?;
    if let Some(path) = parsed.audio_path.as_deref() {
        return run_audio(&parsed.api_key, path);
    }

    let input = read_stdin()?;

    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let result = rt
        .block_on(whisp_lib::post_processor::post_process(
            LlmModel::Gemini25FlashLite,
            &parsed.api_key,
            input.trim(),
            "auto",
            None,
            &[],
            None,
        ))
        .map_err(|e| e.to_string())?;
    println!("{}", result.text);
    if let Some(usage) = result.usage {
        eprintln!(
            "[usage] model: {}, prompt: {}, completion: {}",
            usage.model, usage.prompt_tokens, usage.completion_tokens
        );
    }
    Ok(())
}

#[derive(Debug)]
struct ParsedArgs {
    api_key: String,
    audio_path: Option<String>,
}

fn parse_args(args: &[String], env_api_key: Option<String>) -> Result<ParsedArgs, String> {
    match args.len() {
        0 => {
            let api_key = env_api_key.ok_or_else(|| "GEMINI_API_KEYが必要です".to_string())?;
            Ok(ParsedArgs {
                api_key,
                audio_path: None,
            })
        }
        1 => match env_api_key {
            Some(api_key) => Ok(ParsedArgs {
                api_key,
                audio_path: Some(args[0].clone()),
            }),
            None => Ok(ParsedArgs {
                api_key: args[0].clone(),
                audio_path: None,
            }),
        },
        _ => Ok(ParsedArgs {
            api_key: args[0].clone(),
            audio_path: Some(args[1].clone()),
        }),
    }
}

fn read_stdin() -> Result<String, String> {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())?;
    if input.trim().is_empty() {
        return Err("stdinにテキストを渡してください".to_string());
    }
    Ok(input)
}

fn run_audio(api_key: &str, path: &str) -> Result<(), String> {
    let audio = std::fs::read(Path::new(path)).map_err(|e| e.to_string())?;
    let mime_type = mime_type_from_path(path)?;
    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let result = rt
        .block_on(whisp_lib::post_processor::transcribe_audio_gemini(
            api_key,
            &audio,
            &mime_type,
        ))
        .map_err(|e| e.to_string())?;
    println!("{}", result.text);
    if let Some(usage) = result.usage {
        eprintln!(
            "[usage] model: {}, prompt: {}, completion: {}",
            usage.model, usage.prompt_tokens, usage.completion_tokens
        );
    }
    Ok(())
}

fn mime_type_from_path(path: &str) -> Result<String, String> {
    let ext = Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "wav" => Ok("audio/wav".to_string()),
        "mp3" => Ok("audio/mpeg".to_string()),
        "aiff" | "aif" => Ok("audio/aiff".to_string()),
        "aac" => Ok("audio/aac".to_string()),
        "ogg" => Ok("audio/ogg".to_string()),
        "flac" => Ok("audio/flac".to_string()),
        _ => Err("対応フォーマット: wav/mp3/aiff/aac/ogg/flac".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn uses_env_key_with_single_audio_arg() {
        let parsed = parse_args(&args(&["audio.wav"]), Some("ENV_KEY".to_string())).unwrap();
        assert_eq!(parsed.api_key, "ENV_KEY");
        assert_eq!(parsed.audio_path.as_deref(), Some("audio.wav"));
    }

    #[test]
    fn uses_cli_key_when_no_env_key() {
        let parsed = parse_args(&args(&["CLI_KEY"]), None).unwrap();
        assert_eq!(parsed.api_key, "CLI_KEY");
        assert!(parsed.audio_path.is_none());
    }

    #[test]
    fn uses_cli_key_and_audio_when_two_args() {
        let parsed =
            parse_args(&args(&["CLI_KEY", "audio.wav"]), Some("ENV_KEY".to_string()))
                .unwrap();
        assert_eq!(parsed.api_key, "CLI_KEY");
        assert_eq!(parsed.audio_path.as_deref(), Some("audio.wav"));
    }

    #[test]
    fn requires_env_key_when_no_args() {
        let err = parse_args(&[], None).unwrap_err();
        assert_eq!(err, "GEMINI_API_KEYが必要です");
    }
}
