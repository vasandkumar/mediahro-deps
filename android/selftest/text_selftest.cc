// On-device self-test for the ADR-034 text libraries (lane B4a). Staged by android/selftest/make.sh; the orchestrator
// runs it on the shared Android device per ABI. It loads the shipped libcld3.so and libbergamot.so through dlopen, as the app's dart:ffi loader does, and
// checks:
//   1. CLD3 identifies English and German text (C1's mh_cld3_* API).
//   2. Bergamot creates a service and refuses a missing model with an error message (mh_bergamot_* API). No model
//      ships in the archive, so translating real text is left to the app's integration tests.
//   3. On ARM, simd_utils' exp_ps / log_ps, which Marian uses, agree with libm. On armeabi-v7a they run through
//      patches/simd_utils/0001 (vmlaq_f32 instead of fused vfmaq_f32).
// Prints one line per check and "selftest: PASS" or "selftest: FAIL"; exit status 0 only when everything passes.
#include <dlfcn.h>

#include <cmath>
#include <cstdio>
#include <cstring>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
// As Marian includes it (functional/operators.h), with Marian's ARM defines (run.sh passes -DARM -DSSE -DFMA).
#include "simd_utils.h"
#endif

static int failures = 0;

static void check(bool ok, const char *what, const char *detail) {
  std::printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", what, detail[0] ? ": " : "", detail);
  if (!ok) failures++;
}

template <typename T>
static T sym(void *lib, const char *name) {
  return reinterpret_cast<T>(dlsym(lib, name));
}

static void test_cld3() {
  void *lib = dlopen("libcld3.so", RTLD_NOW | RTLD_LOCAL);
  check(lib != nullptr, "dlopen libcld3.so", lib ? "" : dlerror());
  if (!lib) return;
  auto make = sym<void *(*)(int, int)>(lib, "mh_cld3_new");
  auto find = sym<int (*)(void *, const char *, int, char *, int, float *)>(lib, "mh_cld3_find");
  auto release = sym<void (*)(void *)>(lib, "mh_cld3_free");
  check(make && find && release, "mh_cld3_* symbols", "");
  if (!make || !find || !release) return;
  void *id = make(0, 512);
  check(id != nullptr, "mh_cld3_new(0, 512)", "");
  const struct { const char *text, *lang; } cases[] = {
      {"The weather is lovely today, so we are going for a long walk in the park.", "en"},
      {"Das Wetter ist heute schön, deshalb machen wir einen langen Spaziergang im Park.", "de"},
  };
  for (const auto &c : cases) {
    char lang[16] = {0}, detail[96];
    float p = 0;
    int reliable = find(id, c.text, static_cast<int>(std::strlen(c.text)), lang, sizeof lang, &p);
    std::snprintf(detail, sizeof detail, "got %s (p=%.3f, reliable=%d), want %s", lang, p, reliable, c.lang);
    check(reliable == 1 && std::strcmp(lang, c.lang) == 0, "mh_cld3_find", detail);
  }
  release(id);
}

static void test_bergamot() {
  void *lib = dlopen("libbergamot.so", RTLD_NOW | RTLD_LOCAL);
  check(lib != nullptr, "dlopen libbergamot.so", lib ? "" : dlerror());
  if (!lib) return;
  auto make = sym<void *(*)(int)>(lib, "mh_bergamot_new");
  auto load = sym<void *(*)(void *, const char *, char *, int)>(lib, "mh_bergamot_load");
  auto release = sym<void (*)(void *)>(lib, "mh_bergamot_free");
  check(make && load && release, "mh_bergamot_* symbols", "");
  if (!make || !load || !release) return;
  void *service = make(0);
  check(service != nullptr, "mh_bergamot_new(0)", "");
  if (!service) return;
  char err[256] = {0};
  void *model = load(service,
                     "models:\n  - /nonexistent/model.intgemm8.bin\n"
                     "vocabs:\n  - /nonexistent/vocab.spm\n  - /nonexistent/vocab.spm\n",
                     err, sizeof err);
  char detail[300];
  std::snprintf(detail, sizeof detail, "NULL with message \"%.200s\"", err);
  check(model == nullptr && err[0] != 0, "mh_bergamot_load(missing model) refused", detail);
  release(service);
}

static void test_neon_math() {
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  float worst_exp = 0, worst_log = 0;
  for (float x = -20.0f; x <= 20.0f; x += 0.0625f) {
    float in[4] = {x, x + 0.015625f, x + 0.03125f, x + 0.046875f}, e[4], l[4];
    vst1q_f32(e, exp_ps(vld1q_f32(in)));
    for (int i = 0; i < 4; i++) worst_exp = std::fmax(worst_exp, std::fabs(e[i] - std::exp(in[i])) / std::exp(in[i]));
    float pos[4] = {std::fabs(in[0]) + 1e-3f, std::fabs(in[1]) + 1e-3f, std::fabs(in[2]) + 1e-3f, std::fabs(in[3]) + 1e-3f};
    vst1q_f32(l, log_ps(vld1q_f32(pos)));
    for (int i = 0; i < 4; i++) worst_log = std::fmax(worst_log, std::fabs(l[i] - std::log(pos[i])));
  }
  char detail[96];
  std::snprintf(detail, sizeof detail, "max relative error %.2e (limit 1e-6)", worst_exp);
  check(worst_exp < 1e-6f, "simd_utils exp_ps vs libm", detail);
  std::snprintf(detail, sizeof detail, "max absolute error %.2e (limit 1e-6)", worst_log);
  check(worst_log < 1e-6f, "simd_utils log_ps vs libm", detail);
#else
  check(true, "simd_utils exp_ps/log_ps", "not an ARM build, skipped");
#endif
}

int main() {
  test_cld3();
  test_bergamot();
  test_neon_math();
  std::printf("selftest: %s\n", failures ? "FAIL" : "PASS");
  return failures ? 1 : 0;
}
