/*
 * mediahro_bergamot.h: a C API over the Bergamot translator (MPL-2.0) for
 * dart:ffi (ADR-034, SUB-053).
 *
 * Bergamot is C++ only (marian::bergamot::BlockingService). mediahro-deps
 * compiles mediahro_bergamot.cc (shipped next to this header in the
 * hand-over notes) into the bergamot library and exports these symbols
 * with C linkage. This header is the contract; packages/mediahro_ffi/lib/
 * src/bergamot binds it.
 */
#ifndef MEDIAHRO_BERGAMOT_H
#define MEDIAHRO_BERGAMOT_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define MH_BERGAMOT_API __declspec(dllexport)
#else
#define MH_BERGAMOT_API __attribute__((visibility("default")))
#endif

typedef struct mh_bergamot mh_bergamot;
typedef struct mh_bergamot_model mh_bergamot_model;

/* A blocking translation service with a translation cache of cache_size
 * entries (0 = no cache). NULL on failure. */
MH_BERGAMOT_API mh_bergamot *mh_bergamot_new(int cache_size);

MH_BERGAMOT_API void mh_bergamot_free(mh_bergamot *service);

/* Loads a model from a Marian/Bergamot YAML config naming the model,
 * vocabularies and shortlist by absolute path. On failure returns NULL
 * and writes a NUL-terminated message of at most err_len bytes to err. */
MH_BERGAMOT_API mh_bergamot_model *mh_bergamot_load(mh_bergamot *service,
                                                    const char *config_yaml,
                                                    char *err, int err_len);

MH_BERGAMOT_API void mh_bergamot_model_free(mh_bergamot_model *model);

/* Translates n NUL-terminated UTF-8 plain-text lines (no HTML). On success
 * returns 0 and fills out[0..n-1] with NUL-terminated UTF-8 translations,
 * each freed with mh_bergamot_free_text. Returns -1 on error, with out
 * untouched. */
MH_BERGAMOT_API int mh_bergamot_translate(mh_bergamot *service,
                                          mh_bergamot_model *model,
                                          const char *const *lines, int n,
                                          char **out);

MH_BERGAMOT_API void mh_bergamot_free_text(char *text);

#ifdef __cplusplus
}
#endif

#endif /* MEDIAHRO_BERGAMOT_H */
