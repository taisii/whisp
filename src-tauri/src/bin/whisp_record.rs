use std::env;
use std::time::Duration;

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let out_path = args
        .next()
        .ok_or_else(|| "出力wavパスが必要です".to_string())?;
    let seconds: u64 = args
        .next()
        .unwrap_or_else(|| "5".to_string())
        .parse()
        .map_err(|_| "秒数の指定が不正です".to_string())?;

    let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
    let (audio_tx, mut audio_rx) = tokio::sync::mpsc::channel(8);
    let mut recorder =
        whisp_lib::recorder::RecorderHandle::spawn(audio_tx, None).map_err(|e| e.to_string())?;
    let sample_rate = recorder.sample_rate();

    let bytes = rt.block_on(async move {
        let mut collected = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
        while tokio::time::Instant::now() < deadline {
            if let Some(chunk) = audio_rx.recv().await {
                collected.extend_from_slice(&chunk);
            }
        }
        collected
    });

    recorder.stop();

    let mut writer = hound::WavWriter::create(
        &out_path,
        hound::WavSpec {
            channels: 1,
            sample_rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )
    .map_err(|e| e.to_string())?;

    for chunk in bytes.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
        writer.write_sample(sample).map_err(|e| e.to_string())?;
    }

    writer.finalize().map_err(|e| e.to_string())?;

    println!("saved: {out_path} ({} Hz, {} sec)", sample_rate, seconds);
    Ok(())
}
