//! The small C ABI used by the Swift package.
//!
//! JSON keeps the ABI stable while the core crate remains strongly typed. Every
//! returned string is owned by the caller and must be released with
//! `parchly_string_free`. Handles returned by this module must be freed exactly
//! once, after the caller has stopped using them.

use parchley_core::{Engine, EngineErrorKind, EngineErrorValue, JobHandle, JobRequest};
use serde::Serialize;
use std::path::Path;
use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    sync::Mutex,
};

#[repr(C)]
pub struct ParchlyEngine {
    inner: Engine,
    last_error: Mutex<Option<AbiError>>,
}

#[repr(C)]
pub struct ParchlyJob {
    inner: JobHandle,
}

#[derive(Debug, Serialize)]
struct AbiError {
    kind: EngineErrorKind,
    message: String,
}

fn output(s: String) -> *mut c_char {
    let sanitized = s.replace('\0', "�");
    CString::new(sanitized)
        .expect("NUL characters were removed from ABI output")
        .into_raw()
}

unsafe fn input<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok()
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn set_last_error(engine: &ParchlyEngine, error: Option<AbiError>) {
    *lock(&engine.last_error) = error;
}

fn runtime_error(message: impl Into<String>) -> AbiError {
    AbiError {
        kind: EngineErrorKind::Runtime,
        message: message.into(),
    }
}

fn request_error(message: impl Into<String>) -> AbiError {
    AbiError {
        kind: EngineErrorKind::InvalidRequest,
        message: message.into(),
    }
}

fn start_error(error: EngineErrorValue) -> AbiError {
    AbiError {
        kind: error.kind(),
        message: error.to_string(),
    }
}

#[no_mangle]
pub extern "C" fn parchly_engine_new() -> *mut ParchlyEngine {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(ParchlyEngine {
            inner: Engine::new(),
            last_error: Mutex::new(None),
        }))
    }))
    .unwrap_or(ptr::null_mut())
}

/// Configure bundled OCR runtime paths before the first conversion worker
/// starts. Returns an owned diagnostic string on failure, or null on success.
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_configure_runtime(
    engine: *mut ParchlyEngine,
    pdfium_path: *const c_char,
    ort_path: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        return output("engine handle is missing".into());
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &*engine;
        set_last_error(engine, None);
        let Some(pdfium) = input(pdfium_path) else {
            let error = request_error("PDFium path is missing");
            let message = error.message.clone();
            set_last_error(engine, Some(error));
            return output(message);
        };
        let Some(ort) = input(ort_path) else {
            let error = request_error("ONNX Runtime path is missing");
            let message = error.message.clone();
            set_last_error(engine, Some(error));
            return output(message);
        };
        match engine
            .inner
            .configure_ocr_runtime(Path::new(pdfium), Path::new(ort))
        {
            Ok(()) => ptr::null_mut(),
            Err(message) => {
                set_last_error(engine, Some(runtime_error(message.clone())));
                output(message)
            }
        }
    }))
    .unwrap_or_else(|_| output("runtime configuration panicked".into()))
}

#[no_mangle]
pub unsafe extern "C" fn parchly_engine_free(engine: *mut ParchlyEngine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let engine = Box::from_raw(engine);
        engine.inner.shutdown_and_wait();
    }));
}

/// Returns and clears the last engine-level ABI error as owned JSON.
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_last_error_json(engine: *mut ParchlyEngine) -> *mut c_char {
    if engine.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &*engine;
        lock(&engine.last_error)
            .take()
            .and_then(|error| serde_json::to_string(&error).ok())
            .map(output)
            .unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn parchly_engine_start_json(
    engine: *mut ParchlyEngine,
    request_json: *const c_char,
) -> *mut ParchlyJob {
    if engine.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &*engine;
        set_last_error(engine, None);
        let Some(json) = input(request_json) else {
            set_last_error(
                engine,
                Some(request_error("request JSON is missing or invalid UTF-8")),
            );
            return ptr::null_mut();
        };
        let request = match serde_json::from_str::<JobRequest>(json) {
            Ok(request) => request,
            Err(error) => {
                set_last_error(
                    engine,
                    Some(request_error(format!("request JSON is invalid: {error}"))),
                );
                return ptr::null_mut();
            }
        };
        match engine.inner.start(request) {
            Ok(job) => Box::into_raw(Box::new(ParchlyJob { inner: job })),
            Err(error) => {
                set_last_error(engine, Some(start_error(error)));
                ptr::null_mut()
            }
        }
    }))
    .unwrap_or_else(|_| {
        let engine = &*engine;
        set_last_error(engine, Some(runtime_error("engine start panicked")));
        ptr::null_mut()
    })
}

#[no_mangle]
pub unsafe extern "C" fn parchly_job_snapshot_json(job: *const ParchlyJob) -> *mut c_char {
    if job.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_string(&(*job).inner.snapshot())
            .ok()
            .map(output)
            .unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn parchly_job_cancel(job: *const ParchlyJob) {
    if job.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| (*job).inner.request_cancel()));
}

#[no_mangle]
pub unsafe extern "C" fn parchly_job_result_json(job: *const ParchlyJob) -> *mut c_char {
    if job.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_string(&(*job).inner.result_descriptor())
            .ok()
            .map(output)
            .unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn parchly_job_free(job: *mut ParchlyJob) {
    if job.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(job))));
}

#[no_mangle]
pub unsafe extern "C" fn parchly_string_free(string: *mut c_char) {
    if string.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(string))));
}

#[no_mangle]
pub unsafe extern "C" fn parchly_engine_shutdown(engine: *mut ParchlyEngine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| (*engine).inner.shutdown_request()));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::fs;
    use std::time::{Duration, Instant};

    fn read_owned(pointer: *mut c_char) -> String {
        assert!(!pointer.is_null());
        let value = unsafe { CStr::from_ptr(pointer).to_string_lossy().into_owned() };
        unsafe { parchly_string_free(pointer) };
        value
    }

    fn wait_for_terminal(job: *const ParchlyJob) -> String {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let snapshot = read_owned(unsafe { parchly_job_snapshot_json(job) });
            let value: serde_json::Value = serde_json::from_str(&snapshot).unwrap();
            if matches!(
                value["state"].as_str(),
                Some("Completed" | "Failed" | "Cancelled")
            ) {
                return snapshot;
            }
            assert!(
                Instant::now() < deadline,
                "job did not reach terminal state"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    fn request(input: &str, output: &str) -> CString {
        CString::new(
            serde_json::json!({
                "document_id": "document",
                "attempt_id": "attempt",
                "input_path": input,
                "output_directory": output,
                "page_numbers": null,
                "ocr_mode": "Off",
                "model_directory": null,
                "password": null,
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn malformed_request_reports_structured_abi_error() {
        let engine = parchly_engine_new();
        let request = CString::new("{").unwrap();
        let job = unsafe { parchly_engine_start_json(engine, request.as_ptr()) };
        assert!(job.is_null());
        let error = read_owned(unsafe { parchly_engine_last_error_json(engine) });
        assert!(error.contains("InvalidRequest"));
        unsafe { parchly_engine_free(engine) };
    }

    #[test]
    fn duplicate_cancel_and_shutdown_calls_are_idempotent() {
        let root = std::env::temp_dir().join(format!("parchly-ffi-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let input = root.join("missing.pdf");
        let output = root.join("out");
        let request = request(input.to_str().unwrap(), output.to_str().unwrap());
        let engine = parchly_engine_new();
        let job = unsafe { parchly_engine_start_json(engine, request.as_ptr()) };
        assert!(!job.is_null());
        unsafe {
            parchly_job_cancel(job);
            parchly_job_cancel(job);
            parchly_engine_shutdown(engine);
            parchly_engine_shutdown(engine);
        }
        let snapshot = wait_for_terminal(job);
        assert!(snapshot.contains("Cancelled") || snapshot.contains("FileNotFound"));
        unsafe {
            parchly_job_free(job);
            parchly_engine_free(engine);
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_output_is_null_until_a_result_is_published() {
        let root = std::env::temp_dir().join(format!("parchly-ffi-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let request = request(
            root.join("missing.pdf").to_str().unwrap(),
            root.join("out").to_str().unwrap(),
        );
        let engine = parchly_engine_new();
        let job = unsafe { parchly_engine_start_json(engine, request.as_ptr()) };
        assert!(!job.is_null());
        let _ = wait_for_terminal(job);
        let result = read_owned(unsafe { parchly_job_result_json(job) });
        assert_eq!(result, "null");
        unsafe {
            parchly_job_free(job);
            parchly_engine_free(engine);
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_job_handle_survives_engine_shutdown_until_job_free() {
        let root = std::env::temp_dir().join(format!("parchly-ffi-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let request = request(
            root.join("missing.pdf").to_str().unwrap(),
            root.join("out").to_str().unwrap(),
        );
        let engine = parchly_engine_new();
        let job = unsafe { parchly_engine_start_json(engine, request.as_ptr()) };
        assert!(!job.is_null());
        unsafe { parchly_engine_free(engine) };
        let snapshot = read_owned(unsafe { parchly_job_snapshot_json(job) });
        assert!(snapshot.contains("Failed") || snapshot.contains("Cancelled"));
        unsafe { parchly_job_free(job) };
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn null_abi_inputs_fail_closed() {
        assert!(unsafe { parchly_engine_start_json(ptr::null_mut(), ptr::null()) }.is_null());
        let configuration_error =
            unsafe { parchly_engine_configure_runtime(ptr::null_mut(), ptr::null(), ptr::null()) };
        assert_eq!(read_owned(configuration_error), "engine handle is missing");
        unsafe {
            parchly_string_free(ptr::null_mut());
            parchly_job_cancel(ptr::null());
            parchly_job_free(ptr::null_mut());
        }
    }

    #[test]
    fn invalid_utf8_request_reports_an_abi_failure() {
        let engine = parchly_engine_new();
        let bytes = CString::new(vec![0xff, b'\n']).unwrap();
        assert!(unsafe { parchly_engine_start_json(engine, bytes.as_ptr()) }.is_null());
        let error = read_owned(unsafe { parchly_engine_last_error_json(engine) });
        assert!(error.contains("InvalidRequest"));
        unsafe { parchly_engine_free(engine) };
    }
}
