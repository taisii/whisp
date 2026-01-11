use crate::error::{AppError, AppResult};
use hound::{SampleFormat, WavReader};
use std::path::Path;

pub struct AudioData {
    pub sample_rate: u32,
    pub pcm_bytes: Vec<u8>,
    pub duration_secs: f32,
}

pub fn read_wav_as_mono_i16(path: &Path) -> AppResult<AudioData> {
    let mut reader = WavReader::open(path).map_err(|e| AppError::Audio(e.to_string()))?;
    let spec = reader.spec();

    if spec.sample_format != SampleFormat::Int || spec.bits_per_sample != 16 {
        return Err(AppError::Audio(
            "WAVは16-bit PCMのみ対応しています".to_string(),
        ));
    }

    let channels = spec.channels as usize;
    if channels == 0 {
        return Err(AppError::Audio("channels=0".to_string()));
    }

    let mut mono: Vec<i16> = Vec::new();
    let mut frame: Vec<i16> = Vec::with_capacity(channels);

    for sample in reader.samples::<i16>() {
        let value = sample.map_err(|e| AppError::Audio(e.to_string()))?;
        frame.push(value);
        if frame.len() == channels {
            if channels == 1 {
                mono.push(frame[0]);
            } else {
                let sum: i32 = frame.iter().map(|v| i32::from(*v)).sum();
                let avg = (sum / channels as i32).clamp(i16::MIN as i32, i16::MAX as i32);
                mono.push(avg as i16);
            }
            frame.clear();
        }
    }

    let mut pcm_bytes = Vec::with_capacity(mono.len() * 2);
    for sample in mono.iter() {
        pcm_bytes.extend_from_slice(&sample.to_le_bytes());
    }

    let duration_secs = mono.len() as f32 / spec.sample_rate as f32;

    Ok(AudioData {
        sample_rate: spec.sample_rate,
        pcm_bytes,
        duration_secs,
    })
}
