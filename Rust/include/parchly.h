#pragma once
#include <stdint.h>

typedef struct ParchlyEngine ParchlyEngine;
typedef struct ParchlyJob ParchlyJob;

ParchlyEngine *parchly_engine_new(void);
void parchly_engine_free(ParchlyEngine *);
/* Returns an owned diagnostic string, or NULL on success. */
char *parchly_engine_configure_runtime(ParchlyEngine *, const char *pdfium_path,
                                        const char *ort_path);
/* Returns and clears the last engine-level ABI error as owned JSON. */
char *parchly_engine_last_error_json(ParchlyEngine *);
ParchlyJob *parchly_engine_start_json(ParchlyEngine *, const char *request_json);
char *parchly_job_snapshot_json(const ParchlyJob *);
void parchly_job_cancel(const ParchlyJob *);
char *parchly_job_result_json(const ParchlyJob *);
void parchly_job_free(ParchlyJob *);
void parchly_string_free(char *);
void parchly_engine_shutdown(ParchlyEngine *);

/*
 * All non-NULL pointers must be valid NUL-terminated C strings or handles
 * returned by this ABI. Returned strings belong to the caller and must be
 * released exactly once with parchly_string_free. Handles must be released
 * exactly once after the caller stops using them. NULL is accepted by all
 * free/cancel/shutdown functions and by the query functions, which then fail
 * closed by returning NULL or doing nothing.
 */
