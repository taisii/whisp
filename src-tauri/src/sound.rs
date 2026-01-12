use crate::error::AppResult;
use rodio::{Decoder, OutputStream, Sink};
use std::fs::File;
use std::io::BufReader;

const TINK_PATH: &str = "/System/Library/Sounds/Tink.aiff";

fn play_tink() -> AppResult<()> {
    std::thread::spawn(|| {
        let Ok((_stream, handle)) = OutputStream::try_default() else {
            return;
        };
        let Ok(sink) = Sink::try_new(&handle) else {
            return;
        };
        let Ok(file) = File::open(TINK_PATH) else {
            return;
        };
        let Ok(source) = Decoder::new(BufReader::new(file)) else {
            return;
        };
        sink.append(source);
        sink.sleep_until_end();
    });
    Ok(())
}

pub fn play_completion_sound() -> AppResult<()> {
    play_tink()
}

pub fn play_start_sound() -> AppResult<()> {
    play_tink()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tink_path_is_system_sound() {
        assert_eq!(TINK_PATH, "/System/Library/Sounds/Tink.aiff");
    }
}
