//! Small C ABI used by the Swift package. JSON keeps the ABI stable while the
//! domain crate remains fully typed. Returned strings are freed with
//! `parchly_string_free`.
use parchley_core::{Engine, JobHandle, JobRequest};
use std::path::Path;
use std::{
    ffi::{CStr, CString},
    os::raw::c_char,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
};


#[repr(C)]
pub struct ParchlyEngine {
    inner: Engine,
}
#[repr(C)]
pub struct ParchlyJob {
    inner: JobHandle,
}

unsafe fn input<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}
fn output(s: String) -> *mut c_char {
    CString::new(s)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn parchly_engine_new() -> *mut ParchlyEngine {
    Box::into_raw(Box::new(ParchlyEngine {
        inner: Engine::new(),
    }))
}

/// Set bundled OCR runtime paths before the first conversion worker starts.
/// Returns null on success, otherwise an owned diagnostic string.
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_configure_runtime(
    _engine: *mut ParchlyEngine,
    pdfium_path: *const c_char,
    ort_path: *const c_char,
) -> *mut c_char {
    let Some(pdfium) = input(pdfium_path) else {
        return output("PDFium path is missing".into());
    };
    let Some(ort) = input(ort_path) else {
        return output("ONNX Runtime path is missing".into());
    };
    match parchley_core::configure_ocr_runtime(Path::new(pdfium), Path::new(ort)) {
        Ok(()) => ptr::null_mut(),
        Err(message) => output(message),
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_free(p: *mut ParchlyEngine) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_start_json(
    engine: *mut ParchlyEngine,
    request_json: *const c_char,
) -> *mut ParchlyJob {
    if engine.is_null() {
        return ptr::null_mut();
    }
    let request = match input(request_json).and_then(|s| serde_json::from_str::<JobRequest>(s).ok())
    {
        Some(r) => r,
        None => return ptr::null_mut(),
    };
    match catch_unwind(AssertUnwindSafe(|| (*engine).inner.start(request))) {
        Ok(Ok(job)) => Box::into_raw(Box::new(ParchlyJob { inner: job })),
        _ => ptr::null_mut(),
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_job_snapshot_json(job: *const ParchlyJob) -> *mut c_char {
    if job.is_null() {
        return ptr::null_mut();
    }
    serde_json::to_string(&(*job).inner.snapshot())
        .ok()
        .map(output)
        .unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn parchly_job_cancel(job: *const ParchlyJob) {
    if !job.is_null() {
        (*job).inner.request_cancel();
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_job_result_json(job: *const ParchlyJob) -> *mut c_char {
    if job.is_null() {
        return ptr::null_mut();
    }
    serde_json::to_string(&(*job).inner.result_descriptor())
        .ok()
        .map(output)
        .unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn parchly_job_free(job: *mut ParchlyJob) {
    if !job.is_null() {
        drop(Box::from_raw(job));
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
#[no_mangle]
pub unsafe extern "C" fn parchly_engine_shutdown(engine: *mut ParchlyEngine) {
    if !engine.is_null() {
        (*engine).inner.shutdown_request();
    }
}
