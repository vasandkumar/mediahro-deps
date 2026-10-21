# Minimal ONNX Runtime + face models for IMG-005 People (ADR-046, lane B4a)

Status: **recipe and model pins prepared; nothing downloaded or compiled** (owner: no compiles while device batch 3 runs;
message the orchestrator before downloading anything large). Sizes below are estimates and are replaced by measured
numbers on the first proof build.

## What ships

- `libonnxruntime.so` per Android ABI (arm64-v8a, armeabi-v7a, x86_64): ONNX Runtime **v1.31.0** (MIT), CPU execution
  provider only, reduced to the operators of the two models, built with exceptions and RTTI off and `MinSizeRel`. The
  C API (`onnxruntime_c_api.h`, `OrtGetApiBase`) is the only export, so `ffigen` binds it directly.
- Two models as assets in each Android archive, with their licence texts (`licenses/models/*.LICENSE`):
  - `face_detection_yunet_2023mar.onnx` (OpenCV Zoo, MIT, 232,589 bytes),
  - `face_recognition_sface_2021dec_int8.onnx` (OpenCV Zoo, Apache-2.0 as declared by the Zoo, 9,896,933 bytes).
- No network access at runtime (ORT has none without an execution provider that adds it), no telemetry: ORT's 1DS
  telemetry (cpp_client_telemetry + curl + mbedtls in its `deps.txt`) exists only for opt-in telemetry builds and is not
  built; the build guard below fails if any of it is linked.

### Model pins (done in `versions.json`)

Both files are pinned by SHA-256 at OpenCV Zoo commit `48b10fa505aeb51fbd127fc60a5c660040e823b7` (2026-10-21), downloaded
from `media.githubusercontent.com` (Git LFS media; the same bytes `git lfs` serves). The SHA-256 values are the Git LFS
object ids from the pointer files at that commit and the media server's `Content-Length` matches the pointer sizes:

| File | Bytes | SHA-256 |
|---|---|---|
| face_detection_yunet_2023mar.onnx | 232,589 | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| face_recognition_sface_2021dec_int8.onnx | 9,896,933 | `2b0e941e6f16cc048c20aee0c8e31f569118f65d702914540f7bfdc14048d78a` |

`sources.py` checks them on every fetch (`extract: "file"` copies a single file unchanged). A newer
`face_detection_yunet_2026may.onnx` exists upstream; ADR-046 names 2023mar, so that is what is pinned.

**Provenance (accepted by the owner):** SFace's training data is not stated upstream (opencv_zoo issues #313 and #318). The
model card says only "MobileFaceNet instances trained on the SFace loss function". Licence texts are vendored in
`licenses/models/` from the same commit (`face_detection_yunet.LICENSE` MIT, copyright 2020 Shiqi Yu, sha256
`c83b8120…a958`; `face_recognition_sface.LICENSE` Apache-2.0, sha256 `cfc7749b…3d30`).

## Source pins still to add (needs the download approval)

ORT builds its dependencies with CMake `FetchContent`; the build here runs with `FETCHCONTENT_FULLY_DISCONNECTED=ON` and
`FETCHCONTENT_SOURCE_DIR_<NAME>` pointing at our verified sources, so nothing is fetched at build time. URLs are the ones in
ORT's own `cmake/deps.txt` at v1.31.0 (tag commit `402979ac1bef89dcd55add41eaa7277c407599eb`); each gets a SHA-256 from the
download and a `sha1` field that must equal ORT's pinned SHA-1 (cross-check by an independent statement, recorded as
`upstream-sha1`). `sources.py` gains zip support and the `sha1` field for this (committed on the branch). Names are prefixed
`ort-` where they would clash with existing pins (protobuf 21.12 for CLD3, cpuinfo for ruy).

| Pin | Version | URL | Upstream SHA-1 | Licence | Used for |
|---|---|---|---|---|---|
| onnxruntime | v1.31.0 | github.com/microsoft/onnxruntime/archive/refs/tags/v1.31.0.tar.gz | (tag; commit above) | MIT | the runtime |
| ort-abseil-cpp | 20250814.0 | github.com/abseil/abseil-cpp/archive/refs/tags/20250814.0.zip | a9eb1d648cbca4d4d788737e971a6a7a63726b07 | Apache-2.0 | protobuf, ORT core |
| ort-eigen | 1d8b82b0 | github.com/eigen-mirror/eigen/archive/1d8b82b0740839c0de7f1242a3585e3390ff5f33/eigen-1d8b82b0740839c0de7f1242a3585e3390ff5f33.zip | 05b19b49e6fbb91246be711d801160528c135e34 | MPL-2.0 (header-only; MPL covers only modified Eigen files) | ORT core |
| ort-flatbuffers | v23.5.26 | github.com/google/flatbuffers/archive/refs/tags/v23.5.26.zip | 59422c3b5e573dd192fead2834d25951f1c1670c | Apache-2.0 | ORT-format model loader |
| ort-protobuf | v33.6 | github.com/protocolbuffers/protobuf/releases/download/v33.6/protobuf-33.6.tar.gz | 051fee744fcca04dab37eb009d49aa3e9546acda | BSD-3-Clause | onnx protos (lite) + host `protoc` built from this source |
| ort-onnx | v1.22.0 | github.com/onnx/onnx/archive/refs/tags/v1.22.0.zip | 2b2cd58ac7a26df5371266149e0c76776330cdf1 | Apache-2.0 | operator schemas |
| ort-re2 | 2024-07-02 | github.com/google/re2/archive/refs/tags/2024-07-02.zip | 646e1728269cde7fcef990bf4a8e87b047882e88 | BSD-3-Clause | ORT core (always declared) |
| ort-date | v3.0.1 | github.com/HowardHinnant/date/archive/refs/tags/v3.0.1.zip | 2dac0c81dc54ebdd8f8d073a75c053b04b56e159 | MIT | ORT core |
| ort-mp11 | boost-1.82.0 | github.com/boostorg/mp11/archive/refs/tags/boost-1.82.0.zip | 9bc9e01dffb64d9e0773b2e44d2f22c51aace063 | BSL-1.0 | ORT core |
| ort-json | v3.11.3 | github.com/nlohmann/json/archive/refs/tags/v3.11.3.zip | 5e88795165cc8590138d1f47ce94ee567b85b4d6 | MIT | ORT core |
| ort-cpuinfo | 66ee79c0 | github.com/pytorch/cpuinfo/archive/66ee79c038d70dad9f08705b2c9b3e58f6d8f512.zip | 6e2be17c110e4f4184b059303c722b3c5bd080a6 | BSD-2-Clause | Arm core detection in MLAS |
| ort-gsl | v4.2.1 | github.com/microsoft/GSL/archive/refs/tags/v4.2.1.zip | 1094e3bb7a8af763dcb136ccd676e6e75e614eec | MIT | ORT core |
| ort-safeint | 3.0.28 | github.com/dcleblanc/SafeInt/archive/refs/tags/3.0.28.zip | 23f252040ff6cb9f1fd18575b32fa8fb5928daac | MIT | ORT core |

Not pinned on purpose: XNNPACK, pthreadpool, FP16, FXdiv, psimd (XNNPACK only; off), KleidiAI (optional Arm int8 kernels; off
in the first build, evaluated afterwards), googletest/benchmark, mimalloc, dlpack, cxxopts, pybind11, the CUDA/Dawn/WebGPU/
TensorRT/CoreML pins, and `cpp_client_telemetry`/`curl`/`mbedtls` (telemetry; mbedtls is also on the banned list).
Sizes of the archives are not exposed before downloading; the estimate is roughly 80–120 MB in total, the ORT tarball
(~60 MB) and Eigen being the largest.

## Build recipe (to be implemented in `android/build.sh` after approval)

Minimal build in ORT's sense, **ORT-format models**:

1. **Host tools once per run:** `protoc` from the pinned protobuf v33.6 (the existing `host_protoc` pattern, with abseil from
   the pinned source), and a throw-away Python venv with hash-pinned wheels (`onnx`, `onnxruntime==1.31.0`, `numpy`,
   `flatbuffers`, `protobuf`, `packaging`, `sympy`, ... from a `requirements.lock` with `--require-hashes`) for the model
   converter. Build tools only; nothing from PyPI is shipped.
2. **Convert the models** (once, ABI-independent): `python -m onnxruntime.tools.convert_onnx_models_to_ort <models>
   --optimization_style Fixed --enable_type_reduction --target_platform arm` → `*.ort` plus
   `required_operators_and_types.config`. The config is committed (`android/ort/required_operators.config`) and the build
   fails if a fresh conversion differs, so the operator set is reviewed like any other input.
3. **Reduce and build** per ABI with direct CMake (NDK toolchain, the common hardening/LTO flags, `MinSizeRel`):
   `-Donnxruntime_BUILD_SHARED_LIB=ON -Donnxruntime_MINIMAL_BUILD=ON -Donnxruntime_DISABLE_RTTI=ON
   -Donnxruntime_DISABLE_EXCEPTIONS=ON -Donnxruntime_DISABLE_ML_OPS=ON -Donnxruntime_ENABLE_CPUINFO=ON
   -Donnxruntime_USE_KLEIDIAI=OFF -Donnxruntime_USE_XNNPACK=OFF -Donnxruntime_BUILD_UNIT_TESTS=OFF
   -Donnxruntime_ENABLE_PYTHON=OFF -Donnxruntime_USE_TELEMETRY=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON
   -DFETCHCONTENT_SOURCE_DIR_*=... -DONNX_CUSTOM_PROTOC_EXECUTABLE=<host protoc>`, after running ORT's
   `tools/ci_build/reduce_op_kernels.py` with the committed config (types reduced to those the models use).
4. **Stage:** `libonnxruntime.so` (stripped; SONAME, 16 KB alignment, RELRO/BIND_NOW as everywhere), `include/onnxruntime/`
   C headers, the two `.ort` models under `share/mediahro/models/` with `licenses/models/*.LICENSE`, build-info entries for
   ORT, its static dependencies (`scan_into`) and the models.
5. **Guards:** GPL source scan over the compiled files, `verify_flags` (banned list), `check_elf` (NEEDED only
   libc/libm/libdl/liblog), plus a new check: no `libcurl`/TLS in NEEDED and none of ORT's telemetry endpoints
   (`events.data.microsoft.com`, `vortex`) in the strings of the library.

The minimal runtime cannot load `.onnx` files, so the archive carries the **`.ort`** conversions (about the same size) next to
the pinned `.onnx` sources; the `.onnx` pins stay the source of truth. If the owner wants the `.onnx` files themselves in the
archive too, that adds 10.1 MB per ABI archive (they are not duplicated in the APK, Flutter assets come from one copy).

### Alternative considered: reduced operators without `--minimal_build`

Loads the `.onnx` files directly (no converter, no venv) but links ORT's graph optimisers, the full ONNX schema registry and
protobuf-lite: a few MB larger (estimate +2–4 MB per ABI) and slower to load. Recommended only if the converter proves
brittle.

## Estimates (to be replaced by measurements)

| | arm64-v8a | armeabi-v7a | x86_64 |
|---|---|---|---|
| `libonnxruntime.so` stripped, minimal + reduced ops | 2.5–3.5 MB | 2–3 MB | 3–4.5 MB |
| the alternative (non-minimal) | +2–4 MB | +2–4 MB | +2–4 MB |
| models per ABI archive (YuNet + SFace int8) | 10.1 MB | 10.1 MB | 10.1 MB |

Basis: Microsoft's mobile packages (tens of operators, ORT format) are in the 3–4 MB range per ABI; two small CNNs need fewer
kernels, and the SFace int8 model dominates the model size. The target of 4–5 MB per ABI should hold with margin; the
number to watch is the SFace asset (9.9 MB), not the library. Build time per ABI is estimated at 25–45 minutes with ThinLTO
(ORT minimal is much smaller than a full build), plus about 10 minutes once for host `protoc`.

## Risks

- **armeabi-v7a NEON:** ORT's MLAS has 32-bit Arm kernels; the libaom SIGBUS (clang 19 emitting alignment-hinted
  `vld1`/`vst1` for the multi-register intrinsics) is the pattern to check in the disassembly and in the device self-test.
- **ORT 1.31.0 is three weeks old**; 1.28.3 (a patch release of an older line) and 1.30.0 are the fallbacks if the
  minimal/NDK combination misbehaves.
- **Converter drift:** the `.ort` files depend on the converter version (same 1.31.0 wheel as the runtime) and on
  `--target_platform`; the committed operator config and a hash of the produced models are checked on every release build.
- **SFace provenance** (above): accepted by the owner.
