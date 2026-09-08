//! Run the native OCR path against a real scanned PDF.
//!
//! Usage: cargo run --features ocr --example ocr_smoke -- <pdf> <models> <out>
use parchley_core::{Engine, JobRequest, JobState, OcrMode};
use std::{env, thread, time::Duration};

fn main() {
    let args: Vec<_> = env::args().collect();
    assert_eq!(
        args.len(),
        4,
        "pdf, model directory, and output directory required"
    );
    let engine = Engine::new();
    let job = engine
        .start(JobRequest {
            document_id: "ocr-smoke".into(),
            attempt_id: "ocr-smoke-attempt".into(),
            input_path: args[1].clone(),
            output_directory: args[3].clone(),
            page_numbers: None,
            ocr_mode: OcrMode::Auto,
            model_directory: Some(args[2].clone()),
            password: None,
        })
        .expect("admit OCR job");
    loop {
        let snapshot = job.snapshot();
        eprintln!("{:?} {:?}", snapshot.state, snapshot.stage);
        if matches!(
            snapshot.state,
            JobState::Completed | JobState::Failed | JobState::Cancelled
        ) {
            assert_eq!(
                snapshot.state,
                JobState::Completed,
                "OCR smoke failed: {:?}",
                snapshot.error
            );
            println!(
                "{}",
                job.result_descriptor()
                    .expect("result descriptor")
                    .markdown_path
            );
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
}
