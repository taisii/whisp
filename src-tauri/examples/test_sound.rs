use rodio::{Decoder, OutputStreamBuilder, Sink};
use std::fs::File;
use std::io::BufReader;

fn main() {
    println!("=== rodio 0.21 sound test ===\n");
    
    // Test 1: WAV file
    println!("Test 1: WAV file (/tmp/tink.wav)");
    test_file("/tmp/tink.wav");
    
    println!("\n---\n");
    
    // Test 2: AIFF file
    println!("Test 2: AIFF file (/System/Library/Sounds/Tink.aiff)");
    test_file("/System/Library/Sounds/Tink.aiff");
}

fn test_file(path: &str) {
    // Step 1: Check file exists
    print!("  [1] File exists: ");
    let file = match File::open(path) {
        Ok(f) => { println!("✓"); f }
        Err(e) => { println!("✗ ({})", e); return; }
    };
    
    // Step 2: Try to decode
    print!("  [2] Decoder: ");
    let source = match Decoder::new(BufReader::new(file)) {
        Ok(s) => { println!("✓"); s }
        Err(e) => { println!("✗ ({})", e); return; }
    };
    
    // Step 3: Get output stream (new API in rodio 0.21)
    print!("  [3] Output stream: ");
    let stream = match OutputStreamBuilder::open_default_stream() {
        Ok(s) => { println!("✓"); s }
        Err(e) => { println!("✗ ({})", e); return; }
    };
    
    // Step 4: Create sink
    print!("  [4] Sink: ");
    let sink = Sink::connect_new(&stream.mixer());
    println!("✓");
    
    // Step 5: Play
    println!("  [5] Playing...");
    sink.append(source);
    sink.sleep_until_end();
    println!("  [6] Done ✓");
}
