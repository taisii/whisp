use crate::error::AppResult;
use rodio::{OutputStream, Sink, Source};
use std::time::Duration;

pub fn play_completion_sound() -> AppResult<()> {
    std::thread::spawn(|| {
        if let Ok((_stream, handle)) = OutputStream::try_default() {
            if let Ok(sink) = Sink::try_new(&handle) {
                let source = rodio::source::SineWave::new(880.0)
                    .take_duration(Duration::from_millis(120))
                    .amplify(0.18);
                sink.append(source);
                sink.sleep_until_end();
            }
        }
    });
    Ok(())
}
