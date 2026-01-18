use std::env;

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let file = args
        .next()
        .ok_or_else(|| "wavファイルのパスが必要です".to_string())?;
    let api_key = args
        .next()
        .or_else(|| env::var("DEEPGRAM_API_KEY").ok())
        .ok_or_else(|| "DEEPGRAM_API_KEYが必要です".to_string())?;

    let audio = whisp_lib::audio_file::read_wav_as_mono_i16(std::path::Path::new(&file))
        .map_err(|e| e.to_string())?;

    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let result = rt
        .block_on(whisp_lib::stt_client::run_deepgram_bytes(
            &api_key,
            audio.sample_rate,
            audio.pcm_bytes,
            false,
            None,
            None,
        ))
        .map_err(|e| e.to_string())?;

    println!("{}", result.transcript);
    if let Some(usage) = result.usage {
        eprintln!("[usage] duration: {:.2}s", usage.duration_seconds);
    }
    Ok(())
}
