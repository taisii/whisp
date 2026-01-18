use std::env;
use std::io::{self, Read};
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

    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| e.to_string())?;

    if input.trim().is_empty() {
        return Err("stdinにテキストを渡してください".to_string());
    }

    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let result = rt
        .block_on(whisp_lib::post_processor::post_process(
            LlmModel::Gemini25FlashLite,
            &api_key,
            input.trim(),
            "auto",
            None,
            &[],
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
