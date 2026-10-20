// C API over CLD3 for dart:ffi (Mediahro, ADR-034). Apache-2.0, like CLD3.
#include "mediahro_cld3.h"

#include <cstdio>
#include <new>
#include <string>

#include "nnet_language_identifier.h"

struct mh_cld3 {
  chrome_lang_id::NNetLanguageIdentifier id;
  mh_cld3(int min_bytes, int max_bytes) : id(min_bytes, max_bytes) {}
};

extern "C" {

mh_cld3 *mh_cld3_new(int min_bytes, int max_bytes) {
  if (min_bytes < 0 || max_bytes <= 0 || min_bytes > max_bytes) return nullptr;
  try {
    return new mh_cld3(min_bytes, max_bytes);
  } catch (...) {
    return nullptr;
  }
}

void mh_cld3_free(mh_cld3 *id) { delete id; }

int mh_cld3_find(mh_cld3 *id, const char *utf8, int len, char *out,
                 int out_len, float *probability) {
  if (id == nullptr || utf8 == nullptr || len < 0 || out == nullptr ||
      out_len <= 0) {
    return -1;
  }
  try {
    const auto r = id->id.FindLanguage(std::string(utf8, len));
    std::snprintf(out, static_cast<size_t>(out_len), "%s", r.language.c_str());
    if (probability != nullptr) *probability = r.probability;
    return r.is_reliable ? 1 : 0;
  } catch (...) {
    return -1;
  }
}

}  // extern "C"
