use crate::error::AppResult;
use rodio::{Decoder, OutputStreamBuilder, Sink};
use std::fs::File;
use std::io::BufReader;

const TINK_PATH: &str = "/System/Library/Sounds/Tink.aiff";

fn play_tink() -> AppResult<()> {
    std::thread::spawn(|| {
        let Ok(stream) = OutputStreamBuilder::open_default_stream() else {
            eprintln!("[sound] Failed to open default stream");
            return;
        };
        let sink = Sink::connect_new(&stream.mixer());
        let Ok(file) = File::open(TINK_PATH) else {
            eprintln!("[sound] Failed to open file: {}", TINK_PATH);
            return;
        };
        let Ok(source) = Decoder::new(BufReader::new(file)) else {
            eprintln!("[sound] Failed to decode file: {}", TINK_PATH);
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
