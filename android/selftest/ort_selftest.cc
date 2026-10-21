// On-device self-test for the minimal ONNX Runtime and the IMG-005 face models (lane B4a, ADR-046). Staged by
// android/selftest/make.sh; the orchestrator runs it on the shared Android device per ABI. It uses only ORT's C API
// (what the app's ffigen bindings call) and loads the two ORT-format models shipped in share/mediahro/models:
//   1. The runtime reports its version and creates an environment and a session per model.
//   2. YuNet (face detector): all outputs are finite float tensors, a repeat run is bit-identical.
//   3. SFace int8 (face embedding, 128 floats): finite, non-zero, deterministic, and two different inputs give
//      different embeddings while the same input gives the same one.
// Synthetic inputs only; real faces are for the app's own tests. Run as: ./ort_selftest <models-dir>
// Prints one line per check and "selftest: PASS" or "selftest: FAIL"; exit status 0 only when everything passes.
#include <time.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "onnxruntime_c_api.h"

static const OrtApi *g_api = nullptr;
static int failures = 0;

static void check(bool ok, const std::string &what, const std::string &detail = "") {
  std::printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", what.c_str(), detail.empty() ? "" : ": ", detail.c_str());
  std::fflush(stdout);
  if (!ok) failures++;
}

static double now_ms() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// Returns true when status is OK; otherwise records a failed check with ORT's message and releases the status.
static bool ok(OrtStatus *st, const std::string &what) {
  if (!st) return true;
  check(false, what, g_api->GetErrorMessage(st));
  g_api->ReleaseStatus(st);
  return false;
}

struct Tensor {
  std::vector<int64_t> shape;
  std::vector<float> data;
};

struct Model {
  OrtSession *session = nullptr;
  std::vector<std::string> in_names, out_names;
  std::vector<std::vector<int64_t>> in_shapes;
};

static bool load(OrtEnv *env, OrtSessionOptions *so, const std::string &path, const std::string &label, Model *m) {
  if (!ok(g_api->CreateSession(env, path.c_str(), so, &m->session), "CreateSession " + label)) return false;
  OrtAllocator *alloc = nullptr;
  if (!ok(g_api->GetAllocatorWithDefaultOptions(&alloc), "GetAllocatorWithDefaultOptions")) return false;
  size_t n_in = 0, n_out = 0;
  if (!ok(g_api->SessionGetInputCount(m->session, &n_in), "SessionGetInputCount")) return false;
  if (!ok(g_api->SessionGetOutputCount(m->session, &n_out), "SessionGetOutputCount")) return false;
  for (size_t i = 0; i < n_in; i++) {
    char *name = nullptr;
    if (!ok(g_api->SessionGetInputName(m->session, i, alloc, &name), "SessionGetInputName")) return false;
    m->in_names.push_back(name);
    ok(g_api->AllocatorFree(alloc, name), "AllocatorFree");
    OrtTypeInfo *ti = nullptr;
    if (!ok(g_api->SessionGetInputTypeInfo(m->session, i, &ti), "SessionGetInputTypeInfo")) return false;
    const OrtTensorTypeAndShapeInfo *info = nullptr;
    if (!ok(g_api->CastTypeInfoToTensorInfo(ti, &info), "CastTypeInfoToTensorInfo") || !info) return false;
    size_t rank = 0;
    if (!ok(g_api->GetDimensionsCount(info, &rank), "GetDimensionsCount")) return false;
    std::vector<int64_t> dims(rank);
    if (!ok(g_api->GetDimensions(info, dims.data(), rank), "GetDimensions")) return false;
    m->in_shapes.push_back(dims);
    g_api->ReleaseTypeInfo(ti);
  }
  for (size_t i = 0; i < n_out; i++) {
    char *name = nullptr;
    if (!ok(g_api->SessionGetOutputName(m->session, i, alloc, &name), "SessionGetOutputName")) return false;
    m->out_names.push_back(name);
    ok(g_api->AllocatorFree(alloc, name), "AllocatorFree");
  }
  return true;
}

// Fills a deterministic picture: seed selects the pattern so two seeds give different inputs.
static void fill(std::vector<float> *v, size_t n, int seed, float scale) {
  v->resize(n);
  uint32_t s = 2463534242u + 7919u * uint32_t(seed);
  for (size_t i = 0; i < n; i++) {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;  // xorshift32
    float smooth = 0.5f + 0.5f * std::sin(0.001f * float(i) * float(seed + 1));
    (*v)[i] = scale * (0.6f * smooth + 0.4f * float(s & 0xffff) / 65535.0f);
  }
}

static bool run(Model &m, const std::vector<float> &input, const std::vector<int64_t> &shape, std::vector<Tensor> *outs,
                const std::string &label, double *ms) {
  OrtMemoryInfo *mem = nullptr;
  if (!ok(g_api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem), "CreateCpuMemoryInfo")) return false;
  OrtValue *in = nullptr;
  bool good = ok(g_api->CreateTensorWithDataAsOrtValue(mem, const_cast<float *>(input.data()), input.size() * sizeof(float),
                                                       shape.data(), shape.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in),
                 "CreateTensorWithDataAsOrtValue " + label);
  g_api->ReleaseMemoryInfo(mem);
  if (!good) return false;
  std::vector<const char *> in_names{m.in_names[0].c_str()}, out_names;
  for (auto &n : m.out_names) out_names.push_back(n.c_str());
  std::vector<OrtValue *> out_vals(out_names.size(), nullptr);
  double t0 = now_ms();
  good = ok(g_api->Run(m.session, nullptr, in_names.data(), &in, 1, out_names.data(), out_names.size(), out_vals.data()),
            "Run " + label);
  *ms = now_ms() - t0;
  g_api->ReleaseValue(in);
  if (!good) return false;
  outs->clear();
  for (OrtValue *v : out_vals) {
    OrtTensorTypeAndShapeInfo *info = nullptr;
    Tensor t;
    size_t rank = 0, count = 0;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    good = ok(g_api->GetTensorTypeAndShape(v, &info), "GetTensorTypeAndShape") &&
           ok(g_api->GetTensorElementType(info, &type), "GetTensorElementType") &&
           ok(g_api->GetDimensionsCount(info, &rank), "GetDimensionsCount") &&
           ok(g_api->GetTensorShapeElementCount(info, &count), "GetTensorShapeElementCount");
    if (good) {
      t.shape.resize(rank);
      good = ok(g_api->GetDimensions(info, t.shape.data(), rank), "GetDimensions");
    }
    if (good && type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      check(false, label + ": output element type", std::to_string(int(type)));
      good = false;
    }
    if (good) {
      void *p = nullptr;
      good = ok(g_api->GetTensorMutableData(v, &p), "GetTensorMutableData");
      if (good) t.data.assign(static_cast<float *>(p), static_cast<float *>(p) + count);
    }
    g_api->ReleaseTensorTypeAndShapeInfo(info);
    g_api->ReleaseValue(v);
    if (!good) return false;
    outs->push_back(std::move(t));
  }
  return true;
}

static bool finite_all(const std::vector<Tensor> &outs) {
  for (const auto &t : outs) {
    if (t.data.empty()) return false;
    for (float f : t.data)
      if (!std::isfinite(f)) return false;
  }
  return true;
}

static bool same(const std::vector<Tensor> &a, const std::vector<Tensor> &b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++)
    if (a[i].data.size() != b[i].data.size() || std::memcmp(a[i].data.data(), b[i].data.data(), a[i].data.size() * 4) != 0)
      return false;
  return true;
}

static std::string shape_str(const std::vector<int64_t> &s) {
  std::string r = "[";
  for (size_t i = 0; i < s.size(); i++) r += (i ? "x" : "") + std::to_string(s[i]);
  return r + "]";
}

int main(int argc, char **argv) {
  std::string dir = argc > 1 ? argv[1] : ".";
  const OrtApiBase *base = OrtGetApiBase();
  g_api = base ? base->GetApi(ORT_API_VERSION) : nullptr;
  check(g_api != nullptr, "OrtGetApiBase / GetApi", base ? base->GetVersionString() : "no API base");
  if (!g_api) {
    std::printf("selftest: FAIL\n");
    return 1;
  }
  OrtEnv *env = nullptr;
  OrtSessionOptions *so = nullptr;
  if (!ok(g_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "ort_selftest", &env), "CreateEnv") ||
      !ok(g_api->CreateSessionOptions(&so), "CreateSessionOptions")) {
    std::printf("selftest: FAIL\n");
    return 1;
  }
  // One thread: the determinism checks compare bits, and a repeat run must not depend on thread scheduling.
  ok(g_api->SetIntraOpNumThreads(so, 1), "SetIntraOpNumThreads");

  Model yunet, sface;
  bool have_y = load(env, so, dir + "/face_detection_yunet_2023mar.ort", "YuNet", &yunet);
  bool have_s = load(env, so, dir + "/face_recognition_sface_2021dec_int8.ort", "SFace int8", &sface);
  check(have_y, "YuNet session", have_y ? std::to_string(yunet.out_names.size()) + " outputs, input " + shape_str(yunet.in_shapes[0]) : "");
  check(have_s, "SFace session", have_s ? std::to_string(sface.out_names.size()) + " output, input " + shape_str(sface.in_shapes[0]) : "");

  if (have_y) {
    std::vector<int64_t> shape = yunet.in_shapes[0];
    for (auto &d : shape) if (d <= 0) d = 1;           // batch
    if (shape.size() == 4) { if (shape[2] <= 1) shape[2] = 640; if (shape[3] <= 1) shape[3] = 640; }  // dynamic H, W
    size_t n = 1;
    for (auto d : shape) n *= size_t(d);
    std::vector<float> img;
    fill(&img, n, 1, 255.0f);  // YuNet takes 0..255 pixel values
    std::vector<Tensor> a, b;
    double ms1 = 0, ms2 = 0;
    bool r1 = run(yunet, img, shape, &a, "YuNet run 1", &ms1);
    bool r2 = r1 && run(yunet, img, shape, &b, "YuNet run 2", &ms2);
    check(r1 && finite_all(a), "YuNet outputs are finite float tensors",
          r1 ? std::to_string(a.size()) + " tensors, first " + shape_str(a[0].shape) + ", " + std::to_string(int(ms1)) + " ms" : "");
    check(r2 && same(a, b), "YuNet repeat run is bit-identical", r2 ? std::to_string(int(ms2)) + " ms" : "");
  }

  if (have_s) {
    std::vector<int64_t> shape = sface.in_shapes[0];
    for (auto &d : shape) if (d <= 0) d = 1;
    size_t n = 1;
    for (auto d : shape) n *= size_t(d);
    std::vector<float> img1, img2;
    fill(&img1, n, 3, 255.0f);  // SFace takes an aligned 112x112 face crop in 0..255
    fill(&img2, n, 5, 255.0f);
    std::vector<Tensor> a, b, c;
    double ms1 = 0, ms2 = 0, ms3 = 0;
    bool r1 = run(sface, img1, shape, &a, "SFace run 1", &ms1);
    bool r2 = r1 && run(sface, img1, shape, &b, "SFace run 2", &ms2);
    bool r3 = r2 && run(sface, img2, shape, &c, "SFace run 3", &ms3);
    bool dims = r1 && a.size() == 1 && a[0].data.size() == 128;
    check(dims, "SFace embedding has 128 floats", r1 ? shape_str(a[0].shape) + ", " + std::to_string(int(ms1)) + " ms" : "");
    check(r1 && finite_all(a), "SFace embedding is finite");
    double norm = 0;
    if (dims) for (float f : a[0].data) norm += double(f) * f;
    check(dims && norm > 1e-6, "SFace embedding is not zero", "L2 norm " + std::to_string(std::sqrt(norm)));
    check(r2 && same(a, b), "SFace same input gives the same embedding");
    double cos = 0;
    if (r3 && dims && c[0].data.size() == 128) {
      double dot = 0, nb = 0;
      for (size_t i = 0; i < 128; i++) { dot += double(a[0].data[i]) * c[0].data[i]; nb += double(c[0].data[i]) * c[0].data[i]; }
      cos = dot / (std::sqrt(norm) * std::sqrt(nb) + 1e-12);
    }
    check(r3 && !same(a, c) && cos < 0.9999, "SFace different inputs give different embeddings", "cosine " + std::to_string(cos));
  }

  g_api->ReleaseSessionOptions(so);
  g_api->ReleaseEnv(env);
  std::printf("selftest: %s\n", failures ? "FAIL" : "PASS");
  return failures ? 1 : 0;
}
