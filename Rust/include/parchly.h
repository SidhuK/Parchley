#pragma once
#include <stdint.h>
typedef struct ParchlyEngine ParchlyEngine;
typedef struct ParchlyJob ParchlyJob;
ParchlyEngine *parchly_engine_new(void);
void parchly_engine_free(ParchlyEngine *);
ParchlyJob *parchly_engine_start_json(ParchlyEngine *, const char *request_json);
char *parchly_job_snapshot_json(const ParchlyJob *);
void parchly_job_cancel(const ParchlyJob *);
char *parchly_job_result_json(const ParchlyJob *);
void parchly_job_free(ParchlyJob *);
void parchly_string_free(char *);
void parchly_engine_shutdown(ParchlyEngine *);
