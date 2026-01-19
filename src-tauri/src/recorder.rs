use crate::error::{AppError, AppResult};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use tokio::sync::mpsc::Sender;

pub struct RecorderHandle {
    stop_tx: Option<std::sync::mpsc::Sender<()>>,
    sample_rate: u32,
}

impl RecorderHandle {
    pub fn spawn(
        audio_tx: Sender<Vec<u8>>,
        meter_tx: Option<Sender<u16>>,
    ) -> AppResult<Self> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<AppResult<u32>>();
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();

        std::thread::spawn(move || {
            let setup_result = (|| {
                let host = cpal::default_host();
                let device = host
                    .default_input_device()
                    .ok_or_else(|| AppError::Audio("input device not found".to_string()))?;

                let input_config = device
                    .default_input_config()
                    .map_err(|e| AppError::Audio(e.to_string()))?;

                let sample_rate = input_config.sample_rate().0;
                let channels = input_config.channels() as usize;
                let stream_config: StreamConfig = input_config.clone().into();

                let stream = match input_config.sample_format() {
                    SampleFormat::F32 => {
                        build_stream_f32(&device, &stream_config, channels, audio_tx, meter_tx)?
                    }
                    SampleFormat::I16 => {
                        build_stream_i16(&device, &stream_config, channels, audio_tx, meter_tx)?
                    }
                    SampleFormat::U16 => {
                        build_stream_u16(&device, &stream_config, channels, audio_tx, meter_tx)?
                    }
                    _ => {
                        return Err(AppError::Audio(format!(
                            "unsupported sample format: {:?}",
                            input_config.sample_format()
                        )))
                    }
                };

                stream
                    .play()
                    .map_err(|e| AppError::Audio(e.to_string()))?;

                Ok::<(cpal::Stream, u32), AppError>((stream, sample_rate))
            })();

            let (stream, sample_rate) = match setup_result {
                Ok(value) => value,
                Err(err) => {
                    let _ = ready_tx.send(Err(err));
                    return;
                }
            };

            let _ = ready_tx.send(Ok(sample_rate));
            let _ = stop_rx.recv();
            drop(stream);
        });

        let sample_rate = ready_rx
            .recv()
            .map_err(|e| AppError::Audio(e.to_string()))??;

        Ok(Self {
            stop_tx: Some(stop_tx),
            sample_rate,
        })
    }

    pub fn stop(&mut self) {
        if let Some(tx) = self.stop_tx.take() {
            let _ = tx.send(());
        }
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
}

impl Drop for RecorderHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

fn build_stream_f32(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    audio_tx: Sender<Vec<u8>>,
    meter_tx: Option<Sender<u16>>,
) -> AppResult<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");
    let meter_tx = meter_tx.clone();
    let stream = device
        .build_input_stream(
            config,
            move |data: &[f32], _| {
                let (bytes, peak) = encode_f32(data, channels);
                if let Some(tx) = &meter_tx {
                    let _ = tx.try_send(peak);
                }
                let _ = audio_tx.try_send(bytes);
            },
            err_fn,
            None,
        )
        .map_err(|e| AppError::Audio(e.to_string()))?;
    Ok(stream)
}

fn build_stream_i16(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    audio_tx: Sender<Vec<u8>>,
    meter_tx: Option<Sender<u16>>,
) -> AppResult<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");
    let meter_tx = meter_tx.clone();
    let stream = device
        .build_input_stream(
            config,
            move |data: &[i16], _| {
                let (bytes, peak) = encode_i16(data, channels);
                if let Some(tx) = &meter_tx {
                    let _ = tx.try_send(peak);
                }
                let _ = audio_tx.try_send(bytes);
            },
            err_fn,
            None,
        )
        .map_err(|e| AppError::Audio(e.to_string()))?;
    Ok(stream)
}

fn build_stream_u16(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    audio_tx: Sender<Vec<u8>>,
    meter_tx: Option<Sender<u16>>,
) -> AppResult<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");
    let meter_tx = meter_tx.clone();
    let stream = device
        .build_input_stream(
            config,
            move |data: &[u16], _| {
                let (bytes, peak) = encode_u16(data, channels);
                if let Some(tx) = &meter_tx {
                    let _ = tx.try_send(peak);
                }
                let _ = audio_tx.try_send(bytes);
            },
            err_fn,
            None,
        )
        .map_err(|e| AppError::Audio(e.to_string()))?;
    Ok(stream)
}

fn encode_f32(data: &[f32], channels: usize) -> (Vec<u8>, u16) {
    let mono = downmix_f32(data, channels);
    let mut bytes = Vec::with_capacity(mono.len() * 2);
    let mut peak = 0u16;
    for sample in mono {
        let sample_i16 = f32_to_i16(sample);
        let abs = i32::from(sample_i16).unsigned_abs() as u16;
        if abs > peak {
            peak = abs;
        }
        bytes.extend_from_slice(&sample_i16.to_le_bytes());
    }
    (bytes, peak)
}

fn encode_i16(data: &[i16], channels: usize) -> (Vec<u8>, u16) {
    let mono = downmix_i16(data, channels);
    let mut bytes = Vec::with_capacity(mono.len() * 2);
    let mut peak = 0u16;
    for sample in mono {
        let abs = i32::from(sample).unsigned_abs() as u16;
        if abs > peak {
            peak = abs;
        }
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    (bytes, peak)
}

fn encode_u16(data: &[u16], channels: usize) -> (Vec<u8>, u16) {
    let mono = downmix_u16(data, channels);
    let mut bytes = Vec::with_capacity(mono.len() * 2);
    let mut peak = 0u16;
    for sample in mono {
        let sample_i16 = u16_to_i16(sample);
        let abs = i32::from(sample_i16).unsigned_abs() as u16;
        if abs > peak {
            peak = abs;
        }
        bytes.extend_from_slice(&sample_i16.to_le_bytes());
    }
    (bytes, peak)
}

fn downmix_f32(data: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels)
        .map(|frame| {
            let sum: f32 = frame.iter().copied().sum();
            sum / channels as f32
        })
        .collect()
}

fn downmix_i16(data: &[i16], channels: usize) -> Vec<i16> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels)
        .map(|frame| {
            let sum: i32 = frame.iter().copied().map(i32::from).sum();
            let avg = sum / channels as i32;
            avg.clamp(i16::MIN as i32, i16::MAX as i32) as i16
        })
        .collect()
}

fn downmix_u16(data: &[u16], channels: usize) -> Vec<u16> {
    if channels <= 1 {
        return data.to_vec();
    }
    data.chunks(channels)
        .map(|frame| {
            let sum: u32 = frame.iter().copied().map(u32::from).sum();
            (sum / channels as u32) as u16
        })
        .collect()
}

fn f32_to_i16(sample: f32) -> i16 {
    let clamped = sample.clamp(-1.0, 1.0);
    (clamped * i16::MAX as f32) as i16
}

fn u16_to_i16(sample: u16) -> i16 {
    (sample as i32 - 32768) as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn f32_to_i16_bounds() {
        assert_eq!(f32_to_i16(1.0), i16::MAX);
        assert_eq!(f32_to_i16(-1.0), i16::MIN + 1);
        assert_eq!(f32_to_i16(0.0), 0);
    }

    #[test]
    fn u16_to_i16_center() {
        assert_eq!(u16_to_i16(32768u16), 0);
    }

    #[test]
    fn downmix_f32_average() {
        let stereo = vec![1.0, -1.0, 0.5, 0.5];
        let mono = downmix_f32(&stereo, 2);
        assert_eq!(mono, vec![0.0, 0.5]);
    }
}
