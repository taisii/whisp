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
    let mut args = env::args().skip(1);
    let api_key = match args.next() {
        Some(key) => key,
        None => env::var("GEMINI_API_KEY").map_err(|_| "GEMINI_API_KEYが必要です".to_string())?,
    };
    let audio_path = args.next();
    if let Some(path) = audio_path {
        return run_audio(&api_key, &path);
    }

    let input = read_stdin()?;

    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let output = rt
        .block_on(whisp_lib::post_processor::post_process(
            LlmModel::Gemini25FlashLite,
            &api_key,
            input.trim(),
            "auto",
            None,
            &[],
        ))
        .map_err(|e| e.to_string())?;
    println!("{output}");
    Ok(())
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
    let output = rt
        .block_on(whisp_lib::post_processor::transcribe_audio_gemini(
            api_key,
            &audio,
            &mime_type,
        ))
        .map_err(|e| e.to_string())?;
    println!("{output}");
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
