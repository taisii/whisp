use crate::error::{AppError, AppResult};
use hound::{SampleFormat, WavReader};
use std::path::Path;

pub struct AudioData {
    pub sample_rate: u32,
    pub pcm_bytes: Vec<u8>,
    pub duration_secs: f32,
}

/// Build a WAV file from raw PCM data (16-bit mono little-endian).
pub fn build_wav_bytes(sample_rate: u32, pcm_data: &[u8]) -> Vec<u8> {
    let num_channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * u32::from(num_channels) * u32::from(bits_per_sample) / 8;
    let block_align = num_channels * bits_per_sample / 8;
    let data_size = pcm_data.len() as u32;
    let file_size = 36 + data_size;

    let mut wav = Vec::with_capacity(44 + pcm_data.len());
    // RIFF header
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&file_size.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    // fmt subchunk
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // subchunk1 size
    wav.extend_from_slice(&1u16.to_le_bytes()); // audio format (PCM)
    wav.extend_from_slice(&num_channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    // data subchunk
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());
    wav.extend_from_slice(pcm_data);

    wav
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
