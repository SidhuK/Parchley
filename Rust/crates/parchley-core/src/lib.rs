//! Parchley's local PDF conversion engine.
//!
//! The public types deliberately contain only owned, JSON-compatible values so they
//! can cross UniFFI without borrowing Rust state. Conversion runs on a dedicated
//! worker and the engine admits one job at a time.

use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
};
use thiserror::Error;
use tokio_util::sync::CancellationToken;

pub const ENGINE_VERSION: &str = "0.1.0";
pub const RESULT_SCHEMA_VERSION: u32 = 1;

static RUNTIME_CONFIGURATION: OnceLock<Mutex<Option<(PathBuf, PathBuf)>>> = OnceLock::new();

/// Configure the native OCR libraries once, before any worker can load them.
/// The upstream crates currently discover these paths through environment
/// variables. Keeping the mutation behind OnceLock prevents jobs from racing
/// while changing process-wide loader state.
pub fn configure_ocr_runtime(pdfium: &Path, ort: &Path) -> Result<(), String> {
    if !pdfium.is_file() {
        return Err(format!(
            "PDFium library does not exist: {}",
            pdfium.display()
        ));
    }
    if !ort.is_file() {
        return Err(format!(
            "ONNX Runtime library does not exist: {}",
            ort.display()
        ));
    }

    let configuration = RUNTIME_CONFIGURATION.get_or_init(|| Mutex::new(None));
    let mut configured = configuration.lock().expect("runtime configuration mutex");
    let requested = (pdfium.to_path_buf(), ort.to_path_buf());
    if let Some(existing) = configured.as_ref() {
        return if existing == &requested {
            Ok(())
        } else {
            Err("OCR runtime paths were already configured for this process".into())
        };
    }
    std::env::set_var("PDFIUM_LIB_PATH", pdfium);
    std::env::set_var("ORT_DYLIB_PATH", ort);
    *configured = Some(requested);
    Ok(())
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum OcrMode {
    Off,
    Auto,
    Force,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRequest {
    pub document_id: String,
    pub attempt_id: String,
    pub input_path: String,
    pub output_directory: String,
    pub page_numbers: Option<Vec<u32>>, // one based in the Parchley domain
    pub ocr_mode: OcrMode,
    pub model_directory: Option<String>,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Preparing,
    Converting,
    Cancelling,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum EngineErrorKind {
    InvalidRequest,
    FileNotFound,
    NotPdf,
    PasswordRequired,
    WrongPassword,
    MissingOcrModel,
    Runtime,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineError {
    pub kind: EngineErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobSnapshot {
    pub attempt_id: String,
    pub revision: u64,
    pub state: JobState,
    pub stage: Option<String>,
    pub pages_completed: Option<u32>,
    pub pages_total: Option<u32>,
    pub error: Option<EngineError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageMetadata {
    pub page_number: u32,
    pub method: String,
    pub warning: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResultManifest {
    pub schema_version: u32,
    pub engine_version: String,
    pub model_version: Option<String>,
    pub document_id: String,
    pub attempt_id: String,
    pub completion_status: String,
    pub warnings: Vec<String>,
    pub pages: Vec<PageMetadata>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResultDescriptor {
    pub attempt_id: String,
    pub manifest_path: String,
    pub markdown_path: String,
}

#[derive(Debug, Error)]
pub enum EngineErrorValue {
    #[error("{0}")]
    Failed(String),
}

struct Inner {
    snapshot: Mutex<JobSnapshot>,
    result: Mutex<Option<ResultDescriptor>>,
    cancel: CancellationToken,
}

#[derive(Clone)]
pub struct JobHandle {
    inner: Arc<Inner>,
}

impl JobHandle {
    pub fn snapshot(&self) -> JobSnapshot {
        self.inner.snapshot.lock().expect("snapshot mutex").clone()
    }
    pub fn request_cancel(&self) {
        self.inner.cancel.cancel();
        let mut s = self.inner.snapshot.lock().expect("snapshot mutex");
        if !matches!(
            s.state,
            JobState::Completed | JobState::Failed | JobState::Cancelled
        ) {
            s.state = JobState::Cancelling;
            s.revision += 1;
        }
    }
    pub fn result_descriptor(&self) -> Option<ResultDescriptor> {
        self.inner.result.lock().expect("result mutex").clone()
    }
}

pub struct Engine {
    active: Arc<Mutex<bool>>,
    shutdown: Arc<Mutex<bool>>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}
impl Engine {
    pub fn new() -> Self {
        Self {
            active: Arc::new(Mutex::new(false)),
            shutdown: Arc::new(Mutex::new(false)),
        }
    }
    pub fn start(&self, request: JobRequest) -> Result<JobHandle, EngineErrorValue> {
        validate_request(&request)?;
        if *self.shutdown.lock().expect("shutdown mutex") {
            return Err(EngineErrorValue::Failed("engine is shutting down".into()));
        }
        let mut active = self.active.lock().expect("active mutex");
        if *active {
            return Err(EngineErrorValue::Failed(
                "another conversion is active".into(),
            ));
        }
        *active = true;
        let token = CancellationToken::new();
        let inner = Arc::new(Inner {
            snapshot: Mutex::new(JobSnapshot {
                attempt_id: request.attempt_id.clone(),
                revision: 0,
                state: JobState::Queued,
                stage: None,
                pages_completed: None,
                pages_total: None,
                error: None,
            }),
            result: Mutex::new(None),
            cancel: token.clone(),
        });
        let worker_inner = inner.clone();
        let active_flag = self.active.clone();
        let _spawned = thread::Builder::new()
            .name(format!("parchly-{}", request.attempt_id))
            .spawn(move || {
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_job(request, worker_inner.clone())
                }));
                if worker_inner
                    .snapshot
                    .lock()
                    .map(|s| {
                        !matches!(
                            s.state,
                            JobState::Completed | JobState::Failed | JobState::Cancelled
                        )
                    })
                    .unwrap_or(false)
                {
                    fail(
                        &worker_inner,
                        EngineErrorKind::Runtime,
                        "conversion worker terminated unexpectedly".into(),
                    );
                }
                *active_flag.lock().expect("active mutex") = false;
            })
            .map_err(|e| {
                *active = false;
                EngineErrorValue::Failed(e.to_string())
            })?;
        Ok(JobHandle { inner })
    }
    pub fn release_job(&self, _attempt_id: String) {}
    pub fn shutdown_request(&self) {
        *self.shutdown.lock().expect("shutdown mutex") = true;
    }
}

fn validate_request(r: &JobRequest) -> Result<(), EngineErrorValue> {
    if r.document_id.trim().is_empty()
        || r.attempt_id.trim().is_empty()
        || r.input_path.trim().is_empty()
        || r.output_directory.trim().is_empty()
    {
        return Err(EngineErrorValue::Failed(
            "document, attempt, input, and output identifiers are required".into(),
        ));
    }
    if let Some(pages) = &r.page_numbers {
        if pages.iter().any(|p| *p == 0) {
            return Err(EngineErrorValue::Failed(
                "page numbers are one based".into(),
            ));
        }
        let unique: HashSet<_> = pages.iter().collect();
        if unique.len() != pages.len() {
            return Err(EngineErrorValue::Failed(
                "page numbers must be unique".into(),
            ));
        }
    }
    Ok(())
}

fn set_state(inner: &Inner, state: JobState, stage: Option<&str>, error: Option<EngineError>) {
    let mut s = inner.snapshot.lock().expect("snapshot mutex");
    s.state = state;
    s.stage = stage.map(str::to_owned);
    s.error = error;
    s.revision += 1;
}

fn run_job(r: JobRequest, inner: Arc<Inner>) {
    if inner.cancel.is_cancelled() {
        set_state(
            &inner,
            JobState::Cancelled,
            None,
            Some(EngineError {
                kind: EngineErrorKind::Cancelled,
                message: "conversion cancelled".into(),
            }),
        );
        return;
    }
    set_state(&inner, JobState::Preparing, Some("Reading PDF"), None);
    let input = Path::new(&r.input_path);
    if !input.is_file() {
        fail(
            &inner,
            EngineErrorKind::FileNotFound,
            format!("input PDF does not exist: {}", r.input_path),
        );
        return;
    }
    let bytes = match fs::read(input) {
        Ok(b) => b,
        Err(e) => {
            let message = e.to_string();
            fail(&inner, classify_pdf_error(&message), message);
            return;
        }
    };
    if bytes.len() < 5 || &bytes[..5] != b"%PDF-" {
        fail(&inner, EngineErrorKind::NotPdf, "file is not a PDF".into());
        return;
    }
    if inner.cancel.is_cancelled() {
        cancel(&inner);
        return;
    }
    set_state(
        &inner,
        JobState::Converting,
        Some("Extracting native text"),
        None,
    );
    let mut native_options = pdf_inspector::PdfOptions::new();
    if let Some(password) = &r.password {
        native_options = native_options.password(password.clone());
    }
    if let Some(pages) = &r.page_numbers {
        native_options = native_options.pages(pages.iter().copied());
    }
    let result =
        pdf_inspector::process_pdf_with_options(input.to_string_lossy().as_ref(), native_options);
    let processed = match result {
        Ok(v) => v,
        Err(e) => {
            fail(&inner, EngineErrorKind::Runtime, e.to_string());
            return;
        }
    };
    if inner.cancel.is_cancelled() {
        cancel(&inner);
        return;
    }
    let markdown = processed.markdown.unwrap_or_default();
    let total = processed.page_count as u32;
    if let Some(pages) = &r.page_numbers {
        if pages.iter().any(|p| *p > total) {
            fail(
                &inner,
                EngineErrorKind::InvalidRequest,
                "a selected page is outside the document".into(),
            );
            return;
        }
    }
    {
        let mut s = inner.snapshot.lock().expect("snapshot mutex");
        s.pages_total = Some(total);
        s.pages_completed = Some(total);
        s.revision += 1;
    }
    if r.ocr_mode != OcrMode::Off
        && (r.ocr_mode == OcrMode::Force
            || matches!(
                processed.pdf_type,
                pdf_inspector::PdfType::Scanned
                    | pdf_inspector::PdfType::ImageBased
                    | pdf_inspector::PdfType::Mixed
            ))
    {
        if r.model_directory
            .as_deref()
            .map(|p| Path::new(p).is_dir())
            .unwrap_or(false)
            == false
        {
            fail(
                &inner,
                EngineErrorKind::MissingOcrModel,
                "local OCR model is not installed".into(),
            );
            return;
        }
        set_state(
            &inner,
            JobState::Converting,
            Some("Recognizing scanned pages"),
            None,
        );
        // OCR support is compiled behind the `ocr` feature in release packaging. The
        // default native path never probes model files or a network endpoint.
        #[cfg(feature = "ocr")]
        {
            use pdf_inspector::vision::{
                process_pdf_with_ocr, ModelDownloadPolicy, OcrMode as InspectorOcrMode,
                OcrPdfOptions,
            };
            let mode = match r.ocr_mode {
                OcrMode::Auto => InspectorOcrMode::Auto,
                OcrMode::Force => InspectorOcrMode::Force,
                OcrMode::Off => InspectorOcrMode::Off,
            };
            let mut options = OcrPdfOptions::new().mode(mode);
            options.ocr = options.ocr.model_downloads(ModelDownloadPolicy::Offline);
            if let Some(dir) = &r.model_directory {
                options.ocr = options.ocr.model_directory(dir);
            }
            if let Some(password) = &r.password {
                options = options.password(password);
            }
            if let Some(pages) = &r.page_numbers {
                options = options.page_numbers(pages.iter().copied());
            }
            match process_pdf_with_ocr(input, options) {
                Ok(ocr) => {
                    if inner.cancel.is_cancelled() {
                        cancel(&inner);
                        return;
                    }
                    if ocr.markdown.trim().is_empty() {
                        fail(
                            &inner,
                            EngineErrorKind::Runtime,
                            "OCR produced empty Markdown".into(),
                        );
                        return;
                    }
                    let page_details: Vec<(u32, String, Vec<String>)> = ocr
                        .pages
                        .iter()
                        .map(|page| {
                            let source =
                                format!("{:?}", page.provenance.source).to_ascii_lowercase();
                            (page.page_number, source, page.provenance.warnings.clone())
                        })
                        .collect();
                    let warnings: Vec<String> = page_details
                        .iter()
                        .flat_map(|(_, _, warnings)| warnings.iter().cloned())
                        .collect();
                    if let Err(e) = publish_result(
                        &r,
                        &ocr.markdown,
                        total,
                        &inner,
                        Some(&ocr.pages_routed_to_ocr),
                        Some(&page_details),
                        Some(&warnings),
                        ocr.pages
                            .first()
                            .map(|page| {
                                page.provenance
                                    .ocr_model
                                    .as_ref()
                                    .map(|model| model.revision.as_str())
                            })
                            .flatten(),
                    ) {
                        fail(&inner, EngineErrorKind::Runtime, e);
                        return;
                    }
                    set_state(&inner, JobState::Completed, Some("Complete"), None);
                    return;
                }
                Err(e) => {
                    fail(&inner, EngineErrorKind::Runtime, e.to_string());
                    return;
                }
            }
        }
        #[cfg(not(feature = "ocr"))]
        {
            fail(
                &inner,
                EngineErrorKind::MissingOcrModel,
                "OCR support is not present in this build".into(),
            );
            return;
        }
    }
    if markdown.trim().is_empty() {
        fail(
            &inner,
            EngineErrorKind::Runtime,
            "conversion produced empty Markdown".into(),
        );
        return;
    }
    if r.ocr_mode == OcrMode::Off
        || !matches!(
            processed.pdf_type,
            pdf_inspector::PdfType::Scanned
                | pdf_inspector::PdfType::ImageBased
                | pdf_inspector::PdfType::Mixed
        )
    {
        let warnings: Vec<String> = processed
            .ocr_reasons_by_page
            .iter()
            .map(|reason| format!("Page {}: {}", reason.page, reason.reasons.join(", ")))
            .collect();
        if let Err(e) = publish_result(
            &r,
            &markdown,
            total,
            &inner,
            None,
            None,
            Some(&warnings),
            None,
        ) {
            fail(&inner, EngineErrorKind::Runtime, e);
            return;
        }
    }
    set_state(&inner, JobState::Completed, Some("Complete"), None);
}

fn classify_pdf_error(message: &str) -> EngineErrorKind {
    let lower = message.to_ascii_lowercase();
    if lower.contains("password") && (lower.contains("required") || lower.contains("decrypt")) {
        EngineErrorKind::PasswordRequired
    } else if lower.contains("password")
        && (lower.contains("incorrect") || lower.contains("wrong") || lower.contains("invalid"))
    {
        EngineErrorKind::WrongPassword
    } else {
        EngineErrorKind::Runtime
    }
}

fn publish_result(
    r: &JobRequest,
    markdown: &str,
    pages: u32,
    inner: &Inner,
    ocr_pages: Option<&Vec<u32>>,
    page_details: Option<&Vec<(u32, String, Vec<String>)>>,
    warnings: Option<&Vec<String>>,
    model_version: Option<&str>,
) -> Result<(), String> {
    fs::create_dir_all(&r.output_directory).map_err(|e| e.to_string())?;
    let dir = PathBuf::from(&r.output_directory);
    let md = dir.join("result.md");
    let manifest = dir.join("result.json");
    atomic_write(&md, markdown.as_bytes())?;
    let value = ResultManifest {
        schema_version: RESULT_SCHEMA_VERSION,
        engine_version: ENGINE_VERSION.into(),
        model_version: model_version.map(str::to_owned),
        document_id: r.document_id.clone(),
        attempt_id: r.attempt_id.clone(),
        completion_status: "completed".into(),
        warnings: warnings.cloned().unwrap_or_default(),
        pages: r
            .page_numbers
            .as_ref()
            .map_or_else(|| (1..=pages).collect(), |selected| selected.clone())
            .into_iter()
            .map(|p| PageMetadata {
                page_number: p,
                method: page_details
                    .and_then(|details| {
                        details
                            .iter()
                            .find(|(page, _, _)| *page == p)
                            .map(|(_, method, _)| method.clone())
                    })
                    .unwrap_or_else(|| {
                        if ocr_pages.is_some_and(|ocr| ocr.contains(&p)) {
                            "ocr".into()
                        } else {
                            "native".into()
                        }
                    }),
                warning: page_details.and_then(|details| {
                    details
                        .iter()
                        .find(|(page, _, _)| *page == p)
                        .and_then(|(_, _, warning)| {
                            if warning.is_empty() {
                                None
                            } else {
                                Some(warning.join("; "))
                            }
                        })
                }),
            })
            .collect(),
    };
    atomic_write(
        &manifest,
        serde_json::to_vec_pretty(&value)
            .map_err(|e| e.to_string())?
            .as_slice(),
    )?;
    *inner.result.lock().expect("result mutex") = Some(ResultDescriptor {
        attempt_id: r.attempt_id.clone(),
        manifest_path: manifest.to_string_lossy().into(),
        markdown_path: md.to_string_lossy().into(),
    });
    Ok(())
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}
fn fail(inner: &Inner, kind: EngineErrorKind, message: String) {
    set_state(
        inner,
        JobState::Failed,
        Some("Failed"),
        Some(EngineError { kind, message }),
    );
}
fn cancel(inner: &Inner) {
    fail(
        inner,
        EngineErrorKind::Cancelled,
        "conversion cancelled".into(),
    );
    let mut s = inner.snapshot.lock().expect("snapshot mutex");
    s.state = JobState::Cancelled;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_one_based_pages() {
        let r = JobRequest {
            document_id: "d".into(),
            attempt_id: "a".into(),
            input_path: "x".into(),
            output_directory: "o".into(),
            page_numbers: Some(vec![0]),
            ocr_mode: OcrMode::Off,
            model_directory: None,
            password: None,
        };
        assert!(validate_request(&r).is_err());
    }
    #[test]
    fn result_manifest_is_versioned() {
        assert_eq!(RESULT_SCHEMA_VERSION, 1);
    }

    #[test]
    fn rejects_duplicate_page_selection() {
        let request = JobRequest {
            document_id: "d".into(),
            attempt_id: "a".into(),
            input_path: "x".into(),
            output_directory: "o".into(),
            page_numbers: Some(vec![1, 1]),
            ocr_mode: OcrMode::Off,
            model_directory: None,
            password: None,
        };
        let error = validate_request(&request).expect_err("duplicates must be rejected");
        assert!(error.to_string().contains("unique"));
    }

    #[test]
    fn rejects_missing_ocr_runtime_without_mutating_environment() {
        let error = configure_ocr_runtime(
            Path::new("/definitely/missing/pdfium.dylib"),
            Path::new("/definitely/missing/onnxruntime.dylib"),
        )
        .expect_err("missing runtime must fail closed");
        assert!(error.contains("PDFium"));
    }
}
