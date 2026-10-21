// On-device self-test for the AV1 encoder in libavif.so (lane B4a, ADR-037; IMG-010 AVIF export). Staged by
// android/selftest/make.sh; the orchestrator runs it on the shared Android device per ABI. It links the shipped
// libavif.so (which carries libaom's encoder statically; libdav1d.so decodes) and checks:
//   1. libaom is the AV1 encoder and not a decoder, dav1d is the decoder, and libaom's own symbols are not exported.
//   2. 8-bit 4:2:0 + alpha encodes and decodes back close to the original (RGB PSNR, alpha error).
//   3. 10-bit 4:4:4 does the same (the CONFIG_AV1_HIGHBITDEPTH path that HDR AVIF needs).
//   4. Lossless (identity matrix, 4:4:4) round-trips bit-exactly (the lossless encoder mode).
//   5. A multi-threaded encode (the pthread path) at a speed the app can use for batch convert.
//   6. A sweep over every libavif speed (0..10) with 8-bit 4:2:0 and 10-bit 4:4:4, to reach the SIMD kernels of the slower presets.
// With the argument "bench" it also encodes a 12 MP still at libavif speeds 6 and 8 and prints the time and size.
// Prints one line per check and "selftest: PASS" or "selftest: FAIL"; exit status 0 only when everything passes.
#include <dlfcn.h>
#include <time.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "avif/avif.h"

static int failures = 0;

static void check(bool ok, const char *what, const char *detail) {
  std::printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", what, detail[0] ? ": " : "", detail);
  std::fflush(stdout);
  if (!ok) failures++;
}

static double now_ms() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// Deterministic test picture: smooth colour gradients plus a texture, so lossy coding has something to preserve.
static uint32_t sample(int x, int y, int c, int w, int h, uint32_t maxv) {
  double fx = double(x) / w, fy = double(y) / h;
  double v;
  switch (c) {
    case 0: v = 0.15 + 0.7 * fx + 0.05 * std::sin(40.0 * fy + 9.0 * fx); break;
    case 1: v = 0.15 + 0.7 * fy + 0.05 * std::sin(35.0 * fx); break;
    case 2: v = 0.5 + 0.35 * std::sin(6.0 * (fx + fy)) + 0.04 * std::sin(80.0 * fx * fy); break;
    default: v = 0.2 + 0.8 * fx;  // alpha
  }
  if (v < 0) v = 0;
  if (v > 1) v = 1;
  return uint32_t(v * maxv + 0.5);
}

static void fill(avifRGBImage *rgb, int w, int h) {
  uint32_t maxv = (1u << rgb->depth) - 1;
  int channels = rgb->format == AVIF_RGB_FORMAT_RGBA ? 4 : 3;
  for (int y = 0; y < h; y++) {
    uint8_t *row = rgb->pixels + size_t(y) * rgb->rowBytes;
    for (int x = 0; x < w; x++)
      for (int c = 0; c < channels; c++) {
        uint32_t s = sample(x, y, c, w, h, maxv);
        if (rgb->depth > 8)
          reinterpret_cast<uint16_t *>(row)[x * channels + c] = uint16_t(s);
        else
          row[x * channels + c] = uint8_t(s);
      }
  }
}

static uint32_t px(const avifRGBImage &rgb, int x, int y, int c, int channels) {
  const uint8_t *row = rgb.pixels + size_t(y) * rgb.rowBytes;
  return rgb.depth > 8 ? reinterpret_cast<const uint16_t *>(row)[x * channels + c] : row[x * channels + c];
}

struct Case {
  const char *name;
  int w, h;
  uint32_t depth;
  avifPixelFormat yuv;
  bool alpha, lossless;
  int quality, speed, threads;
  double min_psnr;  // ignored when lossless (exact match required)
};

// Encodes with libaom, decodes with dav1d, compares. Returns the encoded size (0 on failure), the encode time in ms.
static size_t roundtrip(const Case &c, double *encode_ms, bool compare) {
  size_t bytes = 0;
  avifImage *image = avifImageCreate(c.w, c.h, c.depth, c.yuv);
  avifRGBImage rgb;
  std::memset(&rgb, 0, sizeof rgb);
  avifRWData out = AVIF_DATA_EMPTY;
  avifEncoder *enc = nullptr;
  avifDecoder *dec = nullptr;
  avifImage *decoded = nullptr;
  avifRGBImage rgb2;
  std::memset(&rgb2, 0, sizeof rgb2);
  bool rgb2_ready = false, rgb_ready = false;
  char detail[160] = "";

  do {
    if (!image) { std::snprintf(detail, sizeof detail, "avifImageCreate failed"); break; }
    if (c.lossless) {
      image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_IDENTITY;
      image->yuvRange = AVIF_RANGE_FULL;
    }
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = c.alpha ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
    rgb.depth = c.depth;
    avifResult r = avifRGBImageAllocatePixels(&rgb);
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "allocate: %s", avifResultToString(r)); break; }
    rgb_ready = true;
    fill(&rgb, c.w, c.h);
    r = avifImageRGBToYUV(image, &rgb);
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "RGB->YUV: %s", avifResultToString(r)); break; }

    enc = avifEncoderCreate();
    if (!enc) { std::snprintf(detail, sizeof detail, "avifEncoderCreate failed"); break; }
    enc->codecChoice = AVIF_CODEC_CHOICE_AOM;
    enc->speed = c.speed;
    enc->quality = c.lossless ? AVIF_QUALITY_LOSSLESS : c.quality;
    enc->qualityAlpha = c.lossless ? AVIF_QUALITY_LOSSLESS : c.quality;
    enc->maxThreads = c.threads;
    double t0 = now_ms();
    r = avifEncoderWrite(enc, image, &out);
    *encode_ms = now_ms() - t0;
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "encode: %s", avifResultToString(r)); break; }
    bytes = out.size;
    if (out.size == 0) { std::snprintf(detail, sizeof detail, "empty output"); break; }

    dec = avifDecoderCreate();
    decoded = avifImageCreateEmpty();
    if (!dec || !decoded) { std::snprintf(detail, sizeof detail, "decoder alloc failed"); bytes = 0; break; }
    dec->codecChoice = AVIF_CODEC_CHOICE_DAV1D;
    r = avifDecoderReadMemory(dec, decoded, out.data, out.size);
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "decode: %s", avifResultToString(r)); bytes = 0; break; }
    if (decoded->width != uint32_t(c.w) || decoded->height != uint32_t(c.h) || decoded->depth != c.depth) {
      std::snprintf(detail, sizeof detail, "decoded %ux%u depth %u", decoded->width, decoded->height, decoded->depth);
      bytes = 0;
      break;
    }
    if (!compare) break;

    avifRGBImageSetDefaults(&rgb2, decoded);
    rgb2.format = rgb.format;
    rgb2.depth = c.depth;
    r = avifRGBImageAllocatePixels(&rgb2);
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "allocate 2: %s", avifResultToString(r)); bytes = 0; break; }
    rgb2_ready = true;
    r = avifImageYUVToRGB(decoded, &rgb2);
    if (r != AVIF_RESULT_OK) { std::snprintf(detail, sizeof detail, "YUV->RGB: %s", avifResultToString(r)); bytes = 0; break; }

    int channels = c.alpha ? 4 : 3;
    double mse = 0, alpha_err = 0;
    uint64_t mismatches = 0;
    for (int y = 0; y < c.h; y++)
      for (int x = 0; x < c.w; x++) {
        for (int ch = 0; ch < 3; ch++) {
          double d = double(px(rgb, x, y, ch, channels)) - double(px(rgb2, x, y, ch, channels));
          mse += d * d;
          if (d != 0) mismatches++;
        }
        if (c.alpha) alpha_err += std::fabs(double(px(rgb, x, y, 3, channels)) - double(px(rgb2, x, y, 3, channels)));
      }
    mse /= double(c.w) * c.h * 3;
    double peak = double((1u << c.depth) - 1);
    double psnr = mse == 0 ? 99.0 : 10.0 * std::log10(peak * peak / mse);
    double alpha_mae = c.alpha ? alpha_err / (double(c.w) * c.h) / peak * 255.0 : 0.0;
    bool good = c.lossless ? mismatches == 0 : (psnr >= c.min_psnr && alpha_mae <= 4.0);
    std::snprintf(detail, sizeof detail, "%zu bytes, %.0f ms, PSNR %.1f dB%s%s", bytes, *encode_ms, psnr,
                  c.alpha ? ", alpha error " : "", "");
    if (c.alpha) {
      char tail[40];
      std::snprintf(tail, sizeof tail, "%.2f/255", alpha_mae);
      std::strncat(detail, tail, sizeof detail - std::strlen(detail) - 1);
    }
    if (c.lossless) {
      char tail[48];
      std::snprintf(tail, sizeof tail, ", %llu mismatching samples", (unsigned long long)mismatches);
      std::strncat(detail, tail, sizeof detail - std::strlen(detail) - 1);
    }
    check(good, c.name, detail);
    detail[0] = 0;
    if (!good) bytes = 0;
    goto cleanup;
  } while (false);

  if (bytes == 0 || detail[0]) check(false, c.name, detail);
  else if (!compare) {
    char d[80];
    std::snprintf(d, sizeof d, "%zu bytes, %.0f ms", bytes, *encode_ms);
    check(true, c.name, d);
  }
cleanup:
  if (rgb2_ready) avifRGBImageFreePixels(&rgb2);
  if (rgb_ready) avifRGBImageFreePixels(&rgb);
  if (decoded) avifImageDestroy(decoded);
  if (dec) avifDecoderDestroy(dec);
  if (enc) avifEncoderDestroy(enc);
  avifRWDataFree(&out);
  if (image) avifImageDestroy(image);
  return bytes;
}

static void test_codecs() {
  const char *enc = avifCodecName(AVIF_CODEC_CHOICE_AOM, AVIF_CODEC_FLAG_CAN_ENCODE);
  check(enc && std::strcmp(enc, "aom") == 0, "AV1 encoder is aom", enc ? enc : "none");
  check(avifCodecName(AVIF_CODEC_CHOICE_AOM, AVIF_CODEC_FLAG_CAN_DECODE) == nullptr, "aom decoder is not built in", "");
  const char *dec = avifCodecName(AVIF_CODEC_CHOICE_DAV1D, AVIF_CODEC_FLAG_CAN_DECODE);
  check(dec && std::strcmp(dec, "dav1d") == 0, "AV1 decoder is dav1d", dec ? dec : "none");
  void *lib = dlopen("libavif.so", RTLD_NOW | RTLD_NOLOAD);
  if (!lib) lib = dlopen("libavif.so", RTLD_NOW | RTLD_LOCAL);
  check(lib != nullptr, "dlopen libavif.so", lib ? "" : dlerror());
  if (!lib) return;
  check(dlsym(lib, "avifEncoderCreate") != nullptr, "avif* symbols exported", "");
  check(dlsym(lib, "aom_codec_av1_cx") == nullptr && dlsym(lib, "aom_codec_encode") == nullptr,
        "libaom symbols are not exported", "");
}

int main(int argc, char **argv) {
  bool bench = argc > 1 && std::strcmp(argv[1], "bench") == 0;
  std::printf("libavif %s, codecs: %s\n", avifVersion(), [] {
    static char buf[256];
    avifCodecVersions(buf);
    return buf;
  }());
  test_codecs();

  double ms = 0;
  roundtrip({"8-bit 4:2:0 + alpha, quality 60, speed 6", 256, 192, 8, AVIF_PIXEL_FORMAT_YUV420, true, false, 60, 6, 2, 30.0},
            &ms, true);
  roundtrip({"10-bit 4:4:4, quality 60, speed 6", 256, 192, 10, AVIF_PIXEL_FORMAT_YUV444, false, false, 60, 6, 2, 30.0},
            &ms, true);
  roundtrip({"lossless 8-bit 4:4:4 (identity matrix)", 128, 96, 8, AVIF_PIXEL_FORMAT_YUV444, false, true, 100, 6, 1, 0},
            &ms, true);
  roundtrip({"8-bit 4:2:0, 4 threads, speed 8", 512, 384, 8, AVIF_PIXEL_FORMAT_YUV420, false, false, 60, 8, 4, 30.0},
            &ms, true);

  // Every libavif speed (libaom cpu-used 0..9 and the faster mapping at 10) on both pixel paths: the slower presets
  // reach SIMD kernels the speed-6/8 cases above never call, which is where armeabi-v7a alignment bugs hide.
  static char names[22][72];
  int n = 0;
  for (int speed = 0; speed <= 10; speed++) {
    std::snprintf(names[n], sizeof names[n], "sweep 8-bit 4:2:0 q60 speed %d", speed);
    roundtrip({names[n], 192, 128, 8, AVIF_PIXEL_FORMAT_YUV420, false, false, 60, speed, 2, 28.0}, &ms, true);
    n++;
    std::snprintf(names[n], sizeof names[n], "sweep 10-bit 4:4:4 q60 speed %d", speed);
    roundtrip({names[n], 192, 128, 10, AVIF_PIXEL_FORMAT_YUV444, false, false, 60, speed, 2, 28.0}, &ms, true);
    n++;
  }

  if (bench) {
    for (int speed : {6, 8}) {
      char name[96];
      std::snprintf(name, sizeof name, "bench 12 MP (4000x3000) 8-bit 4:2:0 quality 60 speed %d, 4 threads", speed);
      roundtrip({name, 4000, 3000, 8, AVIF_PIXEL_FORMAT_YUV420, false, false, 60, speed, 4, 0}, &ms, false);
    }
  }

  std::printf("selftest: %s\n", failures ? "FAIL" : "PASS");
  return failures ? 1 : 0;
}
