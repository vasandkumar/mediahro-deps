/*
 * mediahro_cld3.h: a C API over CLD3 (Apache-2.0) for dart:ffi (ADR-034).
 *
 * CLD3 is C++ only (chrome_lang_id::NNetLanguageIdentifier). mediahro-deps
 * compiles mediahro_cld3.cc (shipped next to this header in the hand-over
 * notes) into the cld3 library and exports these symbols with C linkage.
 * This header is the contract; packages/mediahro_ffi/lib/src/cld3 binds it.
 */
#ifndef MEDIAHRO_CLD3_H
#define MEDIAHRO_CLD3_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define MH_CLD3_API __declspec(dllexport)
#else
#define MH_CLD3_API __attribute__((visibility("default")))
#endif

typedef struct mh_cld3 mh_cld3;

/* A language identifier that reads between min_bytes and max_bytes of
 * text (CLD3's defaults are 0 and 512). NULL on failure. */
MH_CLD3_API mh_cld3 *mh_cld3_new(int min_bytes, int max_bytes);

MH_CLD3_API void mh_cld3_free(mh_cld3 *id);

/* Identifies the language of len bytes of UTF-8 text. Writes CLD3's code
 * ("en", "zh", "ja-Latn", ..., "und" when unknown) to out as a
 * NUL-terminated string of at most out_len bytes, and the probability
 * (0..1) to *probability. Returns 1 when CLD3 calls the result reliable,
 * 0 when not, -1 on error. */
MH_CLD3_API int mh_cld3_find(mh_cld3 *id, const char *utf8, int len,
                             char *out, int out_len, float *probability);

#ifdef __cplusplus
}
#endif

#endif /* MEDIAHRO_CLD3_H */
