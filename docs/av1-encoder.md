# AV1 encoder for AVIF export (ADR-037, lane B4a)

Status: **built and device-tested** (deps#17, merged as 7c104bd): proof builds on all three ABIs, round-trip self-test
PASS on the Samsung for arm64-v8a and armeabi-v7a (x86_64 is link-time proof only, no x86 device). Sizes are measured
(see "Size and budgets"); the estimates made before the first build were low by about 0.4–1.5 MB per ABI. The release
build is a full clean 3-ABI build from one commit.

## Why

`IMG-010` (batch convert to AVIF) needs an AV1 *encoder* on Android: the pinned archive has libavif + dav1d (decode only)
and Android has no OS AVIF encoder (C3's request, `docs/lanes/requests/c3-imaging.md`). Stills only: no video encode.

## Choice: libaom 3.15.2, encoder only, static into libavif.so

| | libaom | rav1e |
|---|---|---|
| Licence | BSD-2-Clause + AOMedia Patent License 1.0 | BSD-2-Clause + AOMedia Patent License 1.0, plus the licences of its Rust dependencies (a large crate set, to be audited, pinned and vendored) |
| Build | plain CMake, same recipe shape as the other 40+ libraries; perl and nasm are already in the toolchain; official Android NDK support | needs a Rust toolchain with 3 Android targets, cargo-c, a vendored crate set; none of that exists in `mediahro-deps` and the "62 pinned sources, each with SHA-256 + OpenPGP signature" model does not fit crates |
| libavif wiring | `-DAVIF_CODEC_AOM=SYSTEM` (libavif's default and best-tested AV1 encoder; its stills presets target libaom) | `-DAVIF_CODEC_RAV1E=SYSTEM`, fewer still-image tunings |
| ARM SIMD | NEON intrinsics for arm64 and armv7, plus DOTPROD/I8MM/SVE variants picked at run time on arm64 | NEON assembly for arm64 only, as far as I know; armeabi-v7a would run scalar (to be confirmed) |
| Size per ABI (stripped) | measured +4.39 MB arm64, +4.72 MB armv7, +6.56 MB x86_64 (see "Size and budgets") | not built; similar order expected |
| Source pin | one tarball (`libaom-3.15.2.tar.gz`) pinned by SHA-256, tree identical to the git tag (see "How the source is verified") | tarball + vendored crates |

Not considered further: SVT-AV1 (built for server video throughput, large memory, x86 first; wrong tool for stills on
phones) and libgav1 (decoder).

libaom 3.15.2 (2026-10-06) is the newest release and ABI compatible with 3.14.x, which is what libavif 1.4.2's own
tests pin (`AVIF_AOM_GIT_TAG v3.14.1`). 3.15.1/3.15.2 fix still-picture encoder bugs (`reduced_still_picture_header`
frame size, IntraBC motion search), which matters for AVIF.

## Recipe (android/build.sh, before libavif)

    cmake_build libaom -DBUILD_SHARED_LIBS=OFF -DENABLE_APPS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
      -DENABLE_TESTDATA=OFF -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF -DENABLE_NASM=ON \
      -DCONFIG_AV1_DECODER=0 -DCONFIG_AV1_ENCODER=1 -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_REALTIME_ONLY=0 \
      -DCONFIG_RUNTIME_CPU_DETECT=1 -DCONFIG_MULTITHREAD=1 -DCONFIG_WEBM_IO=0 -DCONFIG_TUNE_VMAF=0 \
      -DCONFIG_TUNE_BUTTERAUGLI=0 -DCONFIG_AV1_TEMPORAL_DENOISING=0
    cmake_build libavif ... -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_CODEC_AOM_ENCODE=ON \
      -DCMAKE_SHARED_LINKER_FLAGS="$LDHARDEN -Wl,--exclude-libs,ALL"

- **Static, no new `.so`:** `libaom.a` (PIC) is linked into `libavif.so`; `--exclude-libs,ALL` keeps libaom's symbols
  private, so the exported API stays `avif*`. libaom has no other consumer in the archive (libvips and libjxl do not
  use it), so a shared copy would only add a file and a SONAME to check. `libaom.a` is recorded in build-info like
  protobuf's and is not shipped.
- **dav1d keeps decoding** (`CONFIG_AV1_DECODER=0`, `AVIF_CODEC_AOM_DECODE=OFF`): the decoder is only ~0.4 MB of the 7 MB
  of C source, so this saves little, but nothing links two AV1 decoders.
- **Optimisation level:** libaom is not in `SIZE_LIBS`, so it builds at `-O2` (batch convert speed; ADR-020 keeps speed
  budgets strict). ThinLTO, `--gc-sections` and `--icf=all` come from the common flags.
- **arm CPU detection** uses `getauxval` (API 29 ≥ 18). libaom's CMake still compiles the NDK's
  `cpu-features.c` (Apache-2.0) on ARM, but nothing references it at this API level; `--gc-sections` drops it. Check on the
  first build; if it survives, add the NDK `NOTICE` to the licence bundle.
- **x86_64** assembly needs nasm (already used for dav1d): `-DENABLE_NASM=ON` makes libaom use the toolchain's nasm.
- Licences copied into the archive: libaom `LICENSE` and `PATENTS`, and the `LICENSE` of the bundled `third_party`
  code that is compiled in (libyuv, fastfeat, x86inc, vector).

## What is deliberately *not* trimmed (ADR-020: no feature is cut for size)

| Lever | Saves (estimate) | Why it stays off |
|---|---|---|
| `CONFIG_REALTIME_ONLY=1` | 25–35 % of the encoder | removes the good-quality and all-intra modes that stills need |
| `CONFIG_AV1_HIGHBITDEPTH=0` | 15–25 % | no 10-bit encode, so no HDR AVIF (IMG-002 / IMG-010) |
| dropping SIMD levels (AVX, AVX2, SVE...) | 10–30 % on those ABIs | run-time dispatch is what makes encoding fast on the shipped devices |
| `CONFIG_DENOISE=0` | ~1 % | encoder film-grain/denoise option; tiny, so kept |

## Size and budgets

Measured (stripped `libavif.so`, proof builds of deps#17, `-O2`, ThinLTO, GC, ICF):

| ABI | v2026.10.5-android.1 | with the encoder | growth |
|---|---|---|---|
| arm64-v8a | 211,088 | 4,597,704 | +4.39 MB |
| armeabi-v7a | 157,244 | 4,875,496 | +4.72 MB |
| x86_64 | 202,880 | 6,758,928 | +6.56 MB |

`libdav1d.so` is unchanged. The estimate made before the first build (from Debian's `libaom3` 3.6.0, about 3.5 MiB on
arm64 with decoder and all SIMD) was +3–4 / +2.5–3.5 / +4–5 MB, so libaom 3.15 with its extra arm64 and 32-bit variants
is larger than the reference. libaom at `-Os` gave 3,936,488 bytes on arm64 (-0.66 MB, -14 %) at an unmeasured speed
cost; `-O2` is kept (ADR-020). Current native set (v2026.10.5-android.1, stripped `.so`, 73 libraries): arm64 57.6 MB,
armeabi-v7a 41.3 MB, x86_64 66.9 MB; the arm64 total grows to about 62.0 MB (+7.6 %).

Encode times on the Samsung SM-M176B (Android 16), 12 MP (4000x3000) 8-bit 4:2:0, quality 60, 4 threads: arm64-v8a
965 ms at libavif speed 6 (40,281 B) and 440 ms at speed 8 (44,907 B); armeabi-v7a 1,426 ms (40,276 B) and 521 ms
(44,958 B). The speed sweep 0..10 passes on both (speed 0 on a small image: arm64 309 ms 8-bit / 433 ms 10-bit,
armeabi-v7a 446 / 696 ms). armeabi-v7a with NEON off at run time is about 3–4x slower.

- The file-level >5 % regression gate on `tools/perf/baseline.json` trips for `libavif.so` and for the arm64 total
  (+7.6 %). Per ADR-020 the PR justifies it with `IMG-010` and the orchestrator raises the baseline in the merge commit.
- Whether the **75 MB per-ABI installed ceiling** (ADR-019) still holds depends on the Flutter + app share, which is not
  measured yet; the first app build that embeds the pinned archives decides. If it does not hold, ADR-020 says the ceiling
  is re-set from the measurement, not the feature dropped.
- Speed budgets are unaffected: the encoder runs only in batch convert, off the UI isolate; no cold-start or first-frame
  path loads it (`libavif.so` is loaded on first AVIF use).
- The release archives get the same measurements again (stripped `libavif.so` per ABI, archive size), recorded in the
  release notes.

## Legal note for the owner (docs/09)

libaom is BSD-2-Clause with the AOMedia Patent License 1.0 (royalty-free grant from the Alliance members, with a defensive
termination clause). That grant does not cover third parties outside the Alliance; a commercial AV1 patent pool (Sisvel)
exists and asserts claims against some AV1 products. The app already ships an AV1 *decoder* (dav1d), so adding an encoder
extends an existing exposure rather than creating one; it is the owner's call whether that needs counsel before the
first store release.

## How the source is verified

- **SHA-256 over HTTPS** from Google's official AOM release bucket (`storage.googleapis.com/aom-releases`), the same
  level as libavif and tesseract (`verified: ["https-release-bucket"]` in `versions.json`).
- **No OpenPGP check.** An `.asc` is published (issuer `B002F08B74A148DAA01F7123A48E86DB0B830498`, "AOMedia release signing
  key"), but no independent source confirms that fingerprint: Debian's packaging, the AOM announcements and README,
  libavif's scripts, Nix and web searches name no key, and nothing names a different one either. The key is therefore not
  used and not committed (orchestrator decision: no trust-on-first-use).
- **Tree comparison with the git tag** (2026-10-21): `git clone --depth 1 --branch v3.15.2
  https://aomedia.googlesource.com/aom` (tag commit `af3dc9aadc793c1b00edc003e3fc19a44fdeb574`) against the extracted
  tarball, `diff -rq --exclude=.git`: **no differences**, 1,520 regular files on both sides (checked by a subagent; the
  tag commit and file count re-checked by hand). The tarball is byte-identical to the tag's tree. If the tag cannot be
  reached when the release is built, say so in the PR and the release notes.

## armeabi-v7a: patch `patches/libaom/0001-arm32-clang-single-register-neon.patch`

The first device run (Samsung, Android 16) passed on arm64 and crashed on armeabi-v7a with SIGBUS (BUS_ADRALN) on the
first encode. The crash report named `cfl_predict_lbd_neon` (libavif.so+0x414942): NDK r28's clang turns
`vld1q_s16_x2()` into `vld1.16 {d22-d25}, [r3:256]`, a 256-bit alignment hint, but `CFL_CTX::ac_buf_q3` is only
element-aligned. With `AOM_SIMD_CAPS=0` (NEON off at run time) the same binary passed with identical output sizes,
about 3–4x slower, so the cause was NEON-only. libaom already has single-register fallbacks for the `_x2/_x4`
intrinsics in `aom_dsp/arm/mem_neon.h`, but enables them only for clang <= 6 (Android <= 7). The patch enables them for
every clang on 32-bit Arm (and `#undef`s clang's macro versions first); AArch64 and the NEON kernels themselves are
unchanged. After the fix the rebuilt armv7 `libavif.so` has no 256-bit hinted access left and the CfL kernel uses
plain `vld1.16 {d22, d23}, [r3]!` loads. The self-test now also sweeps libavif speeds 0..10 (8-bit 4:2:0 and 10-bit
4:4:4) to reach the SIMD kernels of the slower presets. Remaining 64/128-bit hints in the armv7 build cannot be audited
statically (about 24,000 sites); they rely on libaom's own `DECLARE_ALIGNED` data being aligned, which the sweep and the
device runs exercise.

## Release

1. Done: proof builds on the three ABIs (`ONLY="dav1d libaom libavif" ONLY_STRICT=1 android/build.sh <out> <abi>`, about
   2 minutes each), the round-trip self-test on the device, and deps#17.
2. The release (v2026.10.6-android.1): a full clean 3-ABI build from one commit (7c104bd, in the `b4a-rel` work tree, no
   cache, a 4 GB free-RAM gate before each ABI), the text and AVIF self-tests staged from the release archives and run by
   the orchestrator, then `gh release create` (pre-release, no workflow) and the deps.lock pin PR, as for
   v2026.10.5-android.1.
