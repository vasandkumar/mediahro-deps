# windows sub-lane (lane B4c)

`windows/build.sh <out-dir>` builds every library in `../versions.json` that applies to Windows, for **windows-x64** and **windows-arm64**. It writes `mediahro-deps-windows-<arch>.tar.gz` plus `.sha256` into `<out-dir>` with `../scripts/package.py`.

It runs from Git Bash or MSYS2 bash (the CI job runs it from Git Bash on `windows-2025`). It re-executes itself under MSYS2 (`C:\msys64`; `MSYS2_ROOT` overrides) for `make`, `perl`, `patch` and `gpg`, and installs those with pacman if they are missing.

## Toolchain

| Piece | Source | Notes |
|---|---|---|
| clang-cl 23 | LLVM release tarball pinned in `deps.json` | Same compiler locally and in CI; `/clang:--target=` picks x64 or arm64 |
| MSVC `link.exe`, `lib.exe`, `rc.exe`, CRT, Windows SDK | Visual Studio 2022 or 2026 found with `vswhere` | arm64 needs the `VC.Tools.ARM64` component |
| meson, ninja, cmake, jinja2 | `requirements.txt`, `pip --require-hashes` | Private venv in the work dir |
| nasm, pkgconf | `deps.json` | pkgconf is built for the host |
| libffi meson port | `deps.json` (wrapdb `libffi_3.8.0-1` patch archive) | Build files only, laid over the verified libffi source |

Hardening on every binary: `/guard:cf` (compile and link), `/GS`, `/DYNAMICBASE`, `/HIGHENTROPYVA`, `/NXCOMPAT`, `/OPT:REF,ICF`, plus `/CETCOMPAT` on x64. The CRT is `/MD`: the app ships the VC++ 2015-2022 runtime, as every Flutter Windows app does. `lib/check_pe.py` fails the build unless every staged DLL meets these checks:
- right machine type
- the four DllCharacteristics bits set, and a CFG function table present
- imports only system DLLs, the MSVC runtime or other DLLs in the archive
- no banned names
- `vulkan-1.dll` only as a delay-load import

`lib/stage_libs.py` ships only import libraries, and each must name a DLL that is staged.

## Sources, patches, licence evidence

- **Sources:** all come from `../versions.json` through the shared `../scripts/sources.py`. It checks SHA-256 and OpenPGP signatures (`../keys/`) before extracting, then applies `../patches/<name>/`. `lib/sources_win.py` runs it from native Python and converts paths for MSYS2's `gpg` and `patch`.
- **Windows patches:** `patches/<name>/` (below) are applied on top.
- **Build-info:** each recipe writes `build-info/<name>.json`, which `package.py` turns into `manifest.json`. It records:
  - the real configure arguments
  - the files produced
  - a source scan of the files actually compiled

  `lib/scan.py` reuses `scripts/source_scan.py`'s classifier. It also adds each object's own source for FFmpeg's MSVC depfiles (those list headers only) and the MSBuild items for libvpx. The build stops if any GPL-only source was compiled.

## Archive layout

| Path | Contents |
|---|---|
| `bin/` | Runtime DLLs: copy them next to the executable. Includes the `ggml-cpu-*.dll` variants whisper.cpp picks at run time (x64). |
| `lib/` | Import libraries for those DLLs, plus `pkgconfig/*.pc` (prefix relative to the file). |
| `include/` | Public headers. |
| `etc/fonts/` | fontconfig configuration (libass/mpv `sub-font-provider=fontconfig`); point `FONTCONFIG_FILE` at `fonts.conf`. |
| `licenses/<name>.txt` | Licence text of every library in the archive. |
| `build-info/`, `manifest.json` | Per library: version, source URL and SHA-256, licence, linking, configure line, files, GPL source scan. Also lists what is not built. |

`vulkan-1.dll` is **not** shipped: GPU drivers install it. libplacebo and mpv link it through `/DELAYLOAD`, and `patches/libplacebo` makes libplacebo report "vulkan-1.dll is not available" instead of faulting. mpv then falls back to D3D11.

## Configuration highlights (docs/05 §4.1, §4.3, §10; docs/09 §2, §4; docs/07 rules 10, 12; ADR-017, ADR-018)

- **FFmpeg** (`../flags/ffmpeg.common.flags` + `../flags/ffmpeg.windows.flags`):
  - LGPL-2.1+, shared, `--disable-everything` plus the explicit components; a misspelt component name fails the build.
  - Hardware decode: D3D11VA, D3D12VA, DXVA2 and Vulkan.
  - CAST-005 hardware encode through Media Foundation (`h264_mf`, `hevc_mf`, `aac_mf`; mfplat.dll is loaded at run time) and D3D12 (`h264/hevc/av1_d3d12va`), plus `scale_d3d11`/`scale_d3d12`.
  - iconv from win-iconv.
  - No TLS in FFmpeg (ADR-017).
- **mpv**: `-Dgpl=false`, no Lua/JS.
  - D3D11, Vulkan, D3D11VA/DXVA2 hwdec, WASAPI.
  - libass with fontconfig and DirectWrite, uchardet + win-iconv, libbluray, lcms2.
  - OpenGL and SMTC are off.
- **libplacebo**: Vulkan + D3D11 (SPIRV-Cross), shaderc, lcms2; no OpenGL.
- **libvips**: `../flags/vips.flags` unchanged; HEIC goes through WIC in the app, and no libheif or libde265 is ever built.
- **curl**: Schannel TLS and SSPI authentication, libssh2 (WinCNG crypto), Windows IDN, zlib/brotli/zstd (ADR-017).
- **libarchive**: Windows CNG hashes; zlib, bzip2, xz, zstd; RAR through libarchive's own reader.
- **glib**: built against the pinned pcre2, libffi and proxy-libintl; no download wraps.
- **libsmb2, libnfs**: the libraries only (LGPL-2.1); their GPL utilities are not built.
- **whisper.cpp**: CPU backends for every x86-64 level, chosen at run time; no OpenMP.
- **chromaprint**: FFT and resampling from FFmpeg (`avtx`, `swresample`).
- No OpenSSL, BoringSSL, mbedTLS or GnuTLS is built.
- No GPL program runs in the build: FFmpeg's arm64 assembly goes through clang-cl's integrated assembler (no gas-preprocessor), and `gperf` is replaced by `patches/fontconfig`'s `gperf-lite.py` (MIT).

## Patches (`patches/<source>/`)

| Source | Why |
|---|---|
| flac | `getopt.c` redeclares `getenv`, which conflicts with the UCRT declaration under clang-cl |
| fontconfig | GNU gperf → `gperf-lite.py` (keeps GPL tools out of the build) |
| libplacebo | Fail cleanly when the delay-loaded `vulkan-1.dll` is missing |
| libudfread | The MSVC CRT has no `ssize_t` |
| mpv | `rc.exe` spells the UTF-8 code page `/c 65001`, not `--codepage=65001` |
| cgif | Export list, so the DLL gets an import library |
| win-iconv | No `USE_LIBICONV_DLL`: never load a DLL named by an environment variable |
| whisper.cpp | ggml's MSVC branch gives clang-cl the AVX-VNNI/BMI2/AMX macros but not the features |
| opus | Windows on Arm64 CPU detection (the MSVC branch emits ARM32 opcodes) |
| libwebp | No ARM32 `-mfpu=neon` for clang-cl on arm64 |

Other Windows-specific steps:
- Own CMake builds where upstream has no MSVC DLL build: `cmake/bzip2`, `cmake/libopenmpt`, `cmake/libraw`, `cmake/libexif`.
- libvpx builds `vpxmd.lib` with its MSBuild projects, then `vpx.dll` is linked from upstream's export lists.
- OpenEXR gets `-msse4.1` on x64. That matches the SSE4.1 baseline its MSVC builds already assume (Windows 11 needs SSE4.2).
- libffi takes its armasm64 path under clang-cl on arm64 (`lib/patch_libffi_wrap.py`).

## Not built

| Library | Why |
|---|---|
| glad | OpenGL loader generator for libplacebo's OpenGL backend, which Windows does not build (D3D11 + Vulkan) |
| openscreen-libcast, vvdec | Removed from mediahro-deps by ADR-017 and ADR-018 (`versions.json` "removed") |

## Local use

```bash
MEDIAHRO_WORK=K:/mw MEDIAHRO_TARGETS=x64 windows/build.sh dist
```

`MEDIAHRO_ONLY=a,b` runs only those recipes; `MEDIAHRO_REBUILD=a,b` ignores their stamps. Keep `MEDIAHRO_WORK` short: some upstream trees have deep paths.
