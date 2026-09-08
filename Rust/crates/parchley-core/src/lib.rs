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
    sync::{Arc, Mutex, MutexGuard},
    thread::{self, JoinHandle},
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
    let mut configured = lock(configuration);
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
    OutputUnavailable,
    Runtime,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineError {
    pub kind: EngineErrorKind,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("another conversion is active")]
    AlreadyActive,
    #[error("engine is shutting down")]
    ShuttingDown,
    #[error("conversion worker could not be started: {0}")]
    Worker(String),
}

impl EngineErrorValue {
    pub fn kind(&self) -> EngineErrorKind {
        match self {
            Self::InvalidRequest(_) => EngineErrorKind::InvalidRequest,
            Self::AlreadyActive | Self::ShuttingDown | Self::Worker(_) => EngineErrorKind::Runtime,
        }
    }
}

struct Inner {
    state: Mutex<JobStateData>,
    cancel: CancellationToken,
}

struct JobStateData {
    snapshot: JobSnapshot,
    result: Option<ResultDescriptor>,
}

struct EngineState {
    shutting_down: bool,
    active: Option<Arc<Inner>>,
    worker: Option<JoinHandle<()>>,
}

struct EngineLifecycle {
    state: Mutex<EngineState>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[derive(Clone)]
pub struct JobHandle {
    inner: Arc<Inner>,
}

impl JobHandle {
    pub fn snapshot(&self) -> JobSnapshot {
        lock(&self.inner.state).snapshot.clone()
    }
    pub fn request_cancel(&self) {
        self.inner.cancel.cancel();
        let mut data = lock(&self.inner.state);
        if !is_terminal(&data.snapshot.state) && data.snapshot.state != JobState::Cancelling {
            data.snapshot.state = JobState::Cancelling;
            data.snapshot.stage = Some("Cancelling".into());
            data.snapshot.revision += 1;
        }
    }
    pub fn result_descriptor(&self) -> Option<ResultDescriptor> {
        lock(&self.inner.state).result.clone()
    }
}

pub struct Engine {
    lifecycle: Arc<EngineLifecycle>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}
impl Engine {
    pub fn new() -> Self {
        Self {
            lifecycle: Arc::new(EngineLifecycle {
                state: Mutex::new(EngineState {
                    shutting_down: false,
                    active: None,
                    worker: None,
                }),
            }),
        }
    }
    pub fn start(&self, mut request: JobRequest) -> Result<JobHandle, EngineErrorValue> {
        validate_request(&request)?;
        if request
            .page_numbers
            .as_deref()
            .is_some_and(|pages| pages.is_empty())
        {
            request.page_numbers = None;
        }

        let previous_worker = {
            let mut state = lock(&self.lifecycle.state);
            if state.shutting_down {
                return Err(EngineErrorValue::ShuttingDown);
            }
            if let Some(active) = state.active.as_ref() {
                let terminal = is_terminal(&lock(&active.state).snapshot.state);
                if terminal {
                    state.active = None;
                } else {
                    return Err(EngineErrorValue::AlreadyActive);
                }
            }
            state.worker.take()
        };
        if let Some(worker) = previous_worker {
            let _ = worker.join();
        }

        let token = CancellationToken::new();
        let inner = Arc::new(Inner {
            state: Mutex::new(JobStateData {
                snapshot: JobSnapshot {
                    attempt_id: request.attempt_id.clone(),
                    revision: 0,
                    state: JobState::Queued,
                    stage: None,
                    pages_completed: None,
                    pages_total: None,
                    error: None,
                },
                result: None,
            }),
            cancel: token.clone(),
        });

        let mut state = lock(&self.lifecycle.state);
        if state.shutting_down {
            return Err(EngineErrorValue::ShuttingDown);
        }
        if state.active.is_some() {
            return Err(EngineErrorValue::AlreadyActive);
        }
        state.active = Some(inner.clone());
        let worker_inner = inner.clone();
        let lifecycle = self.lifecycle.clone();
        let _spawned = thread::Builder::new()
            .name(format!("parchly-{}", request.attempt_id))
            .spawn(move || {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_job(request, worker_inner.clone())
                }));
                if outcome.is_err() {
                    fail(
                        &worker_inner,
                        EngineErrorKind::Runtime,
                        "conversion worker terminated unexpectedly".into(),
                    );
                }
                let terminal = {
                    let data = lock(&worker_inner.state);
                    is_terminal(&data.snapshot.state)
                };
                if !terminal {
                    if worker_inner.cancel.is_cancelled() {
                        cancel(&worker_inner);
                    } else {
                        fail(
                            &worker_inner,
                            EngineErrorKind::Runtime,
                            "conversion worker stopped before publishing a terminal state".into(),
                        );
                    }
                }
                let mut state = lock(&lifecycle.state);
                if state
                    .active
                    .as_ref()
                    .is_some_and(|active| Arc::ptr_eq(active, &worker_inner))
                {
                    state.active = None;
                }
            })
            .map_err(|e| {
                state.active = None;
                EngineErrorValue::Worker(e.to_string())
            })?;
        state.worker = Some(_spawned);
        Ok(JobHandle { inner })
    }
    pub fn release_job(&self, _attempt_id: String) {}
    pub fn configure_ocr_runtime(&self, pdfium: &Path, ort: &Path) -> Result<(), String> {
        let state = lock(&self.lifecycle.state);
        if state.active.is_some() {
            return Err("OCR runtime paths must be configured before a conversion starts".into());
        }
        configure_ocr_runtime(pdfium, ort)
    }
    pub fn shutdown_request(&self) {
        let active = {
            let mut state = lock(&self.lifecycle.state);
            state.shutting_down = true;
            state.active.clone()
        };
        if let Some(active) = active {
            JobHandle { inner: active }.request_cancel();
        }
    }
    pub fn shutdown_and_wait(&self) {
        self.shutdown_request();
        let worker = {
            let mut state = lock(&self.lifecycle.state);
            state.worker.take()
        };
        if let Some(worker) = worker {
            let _ = worker.join();
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shutdown_and_wait();
    }
}

fn validate_request(r: &JobRequest) -> Result<(), EngineErrorValue> {
    if r.document_id.trim().is_empty()
        || r.attempt_id.trim().is_empty()
        || r.input_path.trim().is_empty()
        || r.output_directory.trim().is_empty()
    {
        return Err(EngineErrorValue::InvalidRequest(
            "document, attempt, input, and output identifiers are required".into(),
        ));
    }
    if [
        &r.document_id,
        &r.attempt_id,
        &r.input_path,
        &r.output_directory,
    ]
    .iter()
    .any(|value| value.contains('\0'))
    {
        return Err(EngineErrorValue::InvalidRequest(
            "request fields must not contain NUL characters".into(),
        ));
    }
    if !Path::new(&r.input_path).is_absolute() || !Path::new(&r.output_directory).is_absolute() {
        return Err(EngineErrorValue::InvalidRequest(
            "input and output paths must be absolute".into(),
        ));
    }
    if let Some(pages) = &r.page_numbers {
        if pages.iter().any(|p| *p == 0) {
            return Err(EngineErrorValue::InvalidRequest(
                "page numbers are one based".into(),
            ));
        }
        let unique: HashSet<_> = pages.iter().collect();
        if unique.len() != pages.len() {
            return Err(EngineErrorValue::InvalidRequest(
                "page numbers must be unique".into(),
            ));
        }
        if pages.windows(2).any(|pair| pair[0] > pair[1]) {
            return Err(EngineErrorValue::InvalidRequest(
                "page numbers must be in ascending order".into(),
            ));
        }
    }
    Ok(())
}

fn set_state(inner: &Inner, state: JobState, stage: Option<&str>, error: Option<EngineError>) {
    let mut data = lock(&inner.state);
    if is_terminal(&data.snapshot.state) || data.snapshot.state == JobState::Cancelling {
        return;
    }
    data.snapshot.state = state;
    data.snapshot.stage = stage.map(str::to_owned);
    data.snapshot.error = error;
    data.snapshot.revision += 1;
}

fn is_terminal(state: &JobState) -> bool {
    matches!(
        state,
        JobState::Completed | JobState::Failed | JobState::Cancelled
    )
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
            fail(
                &inner,
                classify_pdf_error(&r.password, &e),
                safe_pdf_error_message(&e),
            );
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
    let selected_pages = selected_page_numbers(&r, total);
    let selected_needs_ocr = processed
        .pages_needing_ocr
        .iter()
        .any(|page| selected_pages.contains(page));
    let will_run_ocr = r.ocr_mode != OcrMode::Off
        && (r.ocr_mode == OcrMode::Force || selected_needs_ocr);
    {
        let mut data = lock(&inner.state);
        if is_terminal(&data.snapshot.state) || inner.cancel.is_cancelled() {
            drop(data);
            cancel(&inner);
            return;
        }
        data.snapshot.pages_total = Some(selected_pages.len() as u32);
        data.snapshot.pages_completed = if will_run_ocr {
            None
        } else {
            Some(selected_pages.len() as u32)
        };
        data.snapshot.revision += 1;
    }
    if will_run_ocr {
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
                        ocr.pages.iter().find_map(|page| {
                            page.provenance
                                .ocr_model
                                .as_ref()
                                .map(|model| model.revision.as_str())
                        }),
                    ) {
                        fail(&inner, EngineErrorKind::OutputUnavailable, e);
                        return;
                    }
                    return;
                }
                Err(e) => {
                    fail(&inner, classify_ocr_error(&r.password, &e), e.to_string());
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
            fail(&inner, EngineErrorKind::OutputUnavailable, e);
            return;
        }
    }
}

fn selected_page_numbers(request: &JobRequest, document_pages: u32) -> Vec<u32> {
    request
        .page_numbers
        .clone()
        .unwrap_or_else(|| (1..=document_pages).collect())
}

fn classify_pdf_error(
    password: &Option<String>,
    error: &pdf_inspector::PdfError,
) -> EngineErrorKind {
    match error {
        pdf_inspector::PdfError::NotAPdf(_) => EngineErrorKind::NotPdf,
        pdf_inspector::PdfError::Encrypted => {
            if password.is_some() {
                EngineErrorKind::WrongPassword
            } else {
                EngineErrorKind::PasswordRequired
            }
        }
        _ => EngineErrorKind::Runtime,
    }
}

fn safe_pdf_error_message(error: &pdf_inspector::PdfError) -> String {
    match error {
        pdf_inspector::PdfError::Encrypted => "the PDF password was missing or incorrect".into(),
        pdf_inspector::PdfError::NotAPdf(_) => "file is not a PDF".into(),
        _ => error.to_string(),
    }
}

#[cfg(feature = "ocr")]
fn classify_ocr_error(
    password: &Option<String>,
    error: &pdf_inspector::vision::OcrPipelineError,
) -> EngineErrorKind {
    let message = error.to_string();
    let lower = message.to_ascii_lowercase();
    if lower.contains("encrypted") {
        if password.is_some() {
            EngineErrorKind::WrongPassword
        } else {
            EngineErrorKind::PasswordRequired
        }
    } else if message.contains("invalid; page numbers are 1-indexed")
        || message.contains("outside the valid range")
    {
        EngineErrorKind::InvalidRequest
    } else if lower.contains("model") || lower.contains("artifact") {
        EngineErrorKind::MissingOcrModel
    } else {
        EngineErrorKind::Runtime
    }
}

fn publish_result(
    r: &JobRequest,
    markdown: &str,
    document_pages: u32,
    inner: &Inner,
    ocr_pages: Option<&Vec<u32>>,
    page_details: Option<&Vec<(u32, String, Vec<String>)>>,
    warnings: Option<&Vec<String>>,
    model_version: Option<&str>,
) -> Result<(), String> {
    if inner.cancel.is_cancelled() {
        cancel(inner);
        return Err("conversion cancelled".into());
    }
    set_state(inner, JobState::Converting, Some("Writing result"), None);
    fs::create_dir_all(&r.output_directory).map_err(|e| e.to_string())?;
    let dir = PathBuf::from(&r.output_directory);
    let md = dir.join("result.md");
    let manifest = dir.join("result.json");
    let md_tmp = temporary_output_path(&md, &r.attempt_id);
    let manifest_tmp = temporary_output_path(&manifest, &r.attempt_id);
    let cleanup = || {
        let _ = fs::remove_file(&md_tmp);
        let _ = fs::remove_file(&manifest_tmp);
    };
    if let Err(error) = write_staged_file(&md_tmp, markdown.as_bytes()) {
        cleanup();
        return Err(error);
    }
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
            .map_or_else(
                || (1..=document_pages).collect(),
                |selected| selected.clone(),
            )
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
    let manifest_bytes = match serde_json::to_vec_pretty(&value) {
        Ok(bytes) => bytes,
        Err(error) => {
            cleanup();
            return Err(error.to_string());
        }
    };
    if let Err(error) = write_staged_file(&manifest_tmp, &manifest_bytes) {
        cleanup();
        return Err(error);
    }
    let mut data = lock(&inner.state);
    if inner.cancel.is_cancelled() || data.snapshot.state == JobState::Cancelling {
        drop(data);
        cleanup();
        cancel(inner);
        return Err("conversion cancelled".into());
    }
    if is_terminal(&data.snapshot.state) {
        drop(data);
        cleanup();
        return Err("conversion is already terminal".into());
    }
    fs::rename(&md_tmp, &md).map_err(|error| {
        cleanup();
        error.to_string()
    })?;
    if let Err(error) = fs::rename(&manifest_tmp, &manifest) {
        let _ = fs::remove_file(&md);
        cleanup();
        return Err(error.to_string());
    }
    data.result = Some(ResultDescriptor {
        attempt_id: r.attempt_id.clone(),
        manifest_path: manifest.to_string_lossy().into(),
        markdown_path: md.to_string_lossy().into(),
    });
    data.snapshot.state = JobState::Completed;
    data.snapshot.stage = Some("Complete".into());
    data.snapshot.error = None;
    data.snapshot.revision += 1;
    Ok(())
}

fn temporary_output_path(path: &Path, attempt_id: &str) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("result");
    path.with_file_name(format!(
        ".{file_name}.tmp-{}",
        sanitize_filename_component(attempt_id)
    ))
}

fn sanitize_filename_component(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn write_staged_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    fs::write(path, bytes).map_err(|e| e.to_string())
}
fn fail(inner: &Inner, kind: EngineErrorKind, message: String) {
    let cancelling = {
        let data = lock(&inner.state);
        data.snapshot.state == JobState::Cancelling
    };
    if inner.cancel.is_cancelled() || cancelling {
        cancel(inner);
        return;
    }
    set_state(
        inner,
        JobState::Failed,
        Some("Failed"),
        Some(EngineError { kind, message }),
    );
}
fn cancel(inner: &Inner) {
    let mut data = lock(&inner.state);
    if is_terminal(&data.snapshot.state) {
        return;
    }
    data.snapshot.state = JobState::Cancelled;
    data.snapshot.stage = Some("Cancelled".into());
    data.snapshot.error = Some(EngineError {
        kind: EngineErrorKind::Cancelled,
        message: "conversion cancelled".into(),
    });
    data.snapshot.revision += 1;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_one_based_pages() {
        let r = JobRequest {
            document_id: "d".into(),
            attempt_id: "a".into(),
            input_path: "/tmp/input.pdf".into(),
            output_directory: "/tmp/output".into(),
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
            input_path: "/tmp/input.pdf".into(),
            output_directory: "/tmp/output".into(),
            page_numbers: Some(vec![1, 1]),
            ocr_mode: OcrMode::Off,
            model_directory: None,
            password: None,
        };
        let error = validate_request(&request).expect_err("duplicates must be rejected");
        assert!(error.to_string().contains("unique"));
    }

    #[test]
    fn rejects_malformed_paths_and_unsorted_pages() {
        let mut request = JobRequest {
            document_id: "d".into(),
            attempt_id: "a".into(),
            input_path: "/tmp/input.pdf".into(),
            output_directory: "/tmp/output".into(),
            page_numbers: Some(vec![2, 1]),
            ocr_mode: OcrMode::Off,
            model_directory: None,
            password: None,
        };
        assert!(validate_request(&request).is_err());
        request.page_numbers = None;
        request.input_path = "relative.pdf".into();
        assert!(validate_request(&request).is_err());
        request.input_path = "/tmp/input\0.pdf".into();
        assert!(validate_request(&request).is_err());
    }

    #[test]
    fn cancellation_is_idempotent_and_does_not_change_terminal_state() {
        let inner = Arc::new(Inner {
            state: Mutex::new(JobStateData {
                snapshot: JobSnapshot {
                    attempt_id: "a".into(),
                    revision: 0,
                    state: JobState::Queued,
                    stage: None,
                    pages_completed: None,
                    pages_total: None,
                    error: None,
                },
                result: None,
            }),
            cancel: CancellationToken::new(),
        });
        let handle = JobHandle {
            inner: inner.clone(),
        };
        handle.request_cancel();
        let first = handle.snapshot();
        handle.request_cancel();
        assert_eq!(handle.snapshot().revision, first.revision);
        cancel(&inner);
        let terminal = handle.snapshot();
        cancel(&inner);
        assert_eq!(handle.snapshot(), terminal);
        assert_eq!(terminal.state, JobState::Cancelled);
    }

    #[test]
    fn stale_handle_state_is_isolated_from_a_new_attempt() {
        let make_inner = |attempt_id: &str| {
            Arc::new(Inner {
                state: Mutex::new(JobStateData {
                    snapshot: JobSnapshot {
                        attempt_id: attempt_id.into(),
                        revision: 0,
                        state: JobState::Queued,
                        stage: None,
                        pages_completed: None,
                        pages_total: None,
                        error: None,
                    },
                    result: None,
                }),
                cancel: CancellationToken::new(),
            })
        };
        let old = JobHandle {
            inner: make_inner("old"),
        };
        let new = JobHandle {
            inner: make_inner("new"),
        };
        old.request_cancel();
        assert_eq!(old.snapshot().state, JobState::Cancelling);
        assert_eq!(new.snapshot().state, JobState::Queued);
        assert_eq!(new.snapshot().attempt_id, "new");
    }

    #[test]
    fn password_errors_map_without_exposing_the_password() {
        let error = pdf_inspector::PdfError::Encrypted;
        assert_eq!(
            classify_pdf_error(&None, &error),
            EngineErrorKind::PasswordRequired
        );
        assert_eq!(
            classify_pdf_error(&Some("secret".into()), &error),
            EngineErrorKind::WrongPassword
        );
        assert!(!safe_pdf_error_message(&error).contains("secret"));
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
