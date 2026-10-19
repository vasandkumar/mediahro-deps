# windows sub-lane (lane B4c)

`windows/build.sh <out-dir>` builds every library in `../versions.json` that applies to Windows, for **windows-x64** and **windows-arm64**, and writes `mediahro-deps-windows-<arch>.tar.gz` plus `.sha256` into `<out-dir>` with `../scripts/package.py`.

It runs from Git Bash or MSYS2 bash (the CI matrix runs it from Git Bash on `windows-2025`). It re-executes itself under MSYS2 (`C:\msys64`; `MSYS2_ROOT` overrides) for `make` and `perl`, and installs `make diffutils perl patch zstd` with pacman if they are missing.

## Toolchain

| Piece | Source | Notes |
|---|---|---|
| clang-cl 23 | LLVM release tarball pinned in `deps.json` | Same compiler locally and in CI; `/clang:--target=` picks x64 or arm64 |
| MSVC `link.exe`, `lib.exe`, `rc.exe`, CRT, Windows SDK | Visual Studio 2022+ found with `vswhere` | arm64 needs the `VC.Tools.ARM64` component |
| meson, ninja, cmake, jinja2 | `requirements.txt`, `pip --require-hashes` | Private venv in the work dir |
| nasm, pkgconf, gas-preprocessor | `deps.json` | pkgconf is built for the host; gas-preprocessor only feeds armasm64 for FFmpeg on arm64 |

Hardening on every binary: `/guard:cf` (compile and link), `/GS`, `/DYNAMICBASE`, `/HIGHENTROPYVA`, `/NXCOMPAT`, `/OPT:REF,ICF`, plus `/CETCOMPAT` on x64. The CRT is `/MD`: the app ships the VC++ 2015-2022 runtime, as every Flutter Windows app does. `lib/check_pe.py` fails the build unless every staged DLL meets these checks:
- right machine type
- the four DllCharacteristics bits set, and a CFG function table present
- imports only system DLLs, the MSVC runtime or other DLLs in the archive
- no banned names
- `vulkan-1.dll` only as a delay-load import

## Sources and pins

`lib/pins.py` resolves each source from `../versions.json`. Before extracting anything it checks the download against the SHA-256 pinned there. `deps.json` adds three kinds of pin:
- **toolchain**: build-only tools.
- **extra**: transitive libraries that ship in the archive but are not in `versions.json` (zlib, expat, bzip2, xz, zstd, the Vulkan/SPIR-V stack, highway, brotli, Imath, libdeflate, libudfread, win-iconv; pcre2, libffi and proxy-libintl arrive through glib's meson wraps, which verify their own hashes).
- **fallback**: used only while a `versions.json` entry is still unpinned. `versions.json` always wins once B4a pins it.

`package.py` runs from a packaging root (`pins.py pkgroot`). That root holds the repo's `versions.json` with the fallback pins filled in, the extra libraries appended, and only the libraries this build produced. As a result `manifest.json` lists exactly what is in the archive. Each library's configure line includes the Windows additions from `windows/flags/`.

## Archive layout

| Path | Contents |
|---|---|
| `bin/` | Runtime DLLs: copy them next to the executable. Includes the `ggml-cpu-*.dll` variants whisper.cpp picks at run time. |
| `lib/` | Import libraries for those DLLs, plus `pkgconfig/*.pc` (prefix relative to the file). |
| `include/` | Public headers. |
| `etc/fonts/` | fontconfig configuration (libass/mpv `sub-font-provider=fontconfig`); point `FONTCONFIG_FILE` at `fonts.conf`. |
| `licenses/<name>.txt` | Licence text of every library in the archive. |
| `manifest.json` | Name, version, licence, linking and configure flags of each library (Mediahro licence scan). |

`vulkan-1.dll` is **not** shipped: GPU drivers install it. libplacebo and mpv link it through `/DELAYLOAD`, and `patches/libplacebo` makes libplacebo report "vulkan-1.dll is not available" instead of faulting. mpv then falls back to D3D11.

## Configuration highlights (docs/05 §4.1, §4.3, §10; docs/09 §2, §4; docs/07 rules 10, 12)

- **FFmpeg** (`../flags/ffmpeg.common.flags` + `../flags/ffmpeg.windows.flags`):
  - LGPL-2.1+, shared.
  - Hardware decode: D3D11VA, D3D12VA, DXVA2 and Vulkan.
  - Media Foundation (mfplat.dll loaded at run time) and D3D12 encoders.
  - Schannel TLS.
  - dav1d, libvpx, opus, libopenmpt, zlib, bzip2, lzma.
- **mpv**: `-Dgpl=false`, no Lua/JS.
  - D3D11, Vulkan, D3D11VA/DXVA2 hwdec, WASAPI.
  - libass with fontconfig and DirectWrite, uchardet + win-iconv, libbluray, lcms2.
  - Explicitly off: rubberband, C plugins, OpenGL, SMTC.
- **libplacebo**: Vulkan + D3D11 (SPIRV-Cross), shaderc, lcms2; no OpenGL.
- **libvips**: libvips's own GIF save needs a quantiser, and neither option is usable: libimagequant is GPL-3 and stays disabled, and quantizr needs a Rust toolchain. VID-042 GIF export should use FFmpeg's GIF encoder (palettegen/paletteuse).
  - Loaders/savers on: JPEG, PNG (spng), WebP, TIFF, JPEG XL, EXR, EXIF, lcms2, highway, camera RAW (LibRaw).
  - HEIC/HEIF goes through WIC in the app; no libheif or libde265 is ever built here.
- **curl**: Schannel TLS and SSPI authentication, libssh2 (WinCNG crypto), Windows IDN, zlib/brotli/zstd.
- **libarchive**: Windows CNG hashes; zlib, bzip2, xz, zstd; RAR through libarchive's own reader.
- **libsmb2, libnfs**: the libraries only (LGPL-2.1); their GPL utilities are not built.
- **whisper.cpp**: CPU backends for every x86-64 level, chosen at run time; no OpenMP.
- **chromaprint**: FFT and resampling from FFmpeg (`avtx`, `swresample`).
- No OpenSSL, BoringSSL or other TLS library is built; no GPL code is compiled into any binary.

### Build-time GPL tools

The only GPL program that touches a source is `gas-preprocessor.pl`. On arm64 it rewrites FFmpeg's GNU-syntax assembly for armasm64; it adds no code of its own. `gperf` is **not** used: `patches/fontconfig` replaces it with `gperf-lite.py` (MIT), which writes the two lookup tables.

## Patches (`patches/<source>/`)

| Source | Why |
|---|---|
| flac | `getopt.c` redeclares `getenv`, which conflicts with the UCRT declaration under clang-cl |
| fontconfig | GNU gperf → `gperf-lite.py` (keeps GPL tools out of the build) |
| libplacebo | Fail cleanly when the delay-loaded `vulkan-1.dll` is missing |
| libudfread, libnfs | The MSVC CRT has no `ssize_t` / `strndup`; libnfs declares `struct timezone` at prototype scope |
| mpv | `rc.exe` spells the UTF-8 code page `/c 65001`, not `--codepage=65001` |
| cgif | Export list, so the DLL gets an import library |
| win-iconv | No `USE_LIBICONV_DLL`: never load a DLL named by an environment variable |
| whisper.cpp | ggml's MSVC branch gives clang-cl the AVX-VNNI/BMI2/AMX macros but not the features |

Own CMake builds where upstream has no MSVC DLL build: `cmake/bzip2`, `cmake/libopenmpt`, `cmake/libraw`, `cmake/libexif`. libvpx builds `vpxmd.lib` with its MSBuild projects, then `vpx.dll` is linked from upstream's export lists. OpenEXR and vvdec get `-msse4.1` on x64. That matches the SSE4.1 baseline their MSVC builds already assume (Windows 11 needs SSE4.2).

## Not built

| Library | Why | Tracking |
|---|---|---|
| openscreen-libcast | Upstream has no Windows platform implementation (`platform/impl` is POSIX/Linux/macOS only). Its TLS and Cast device-auth checks use BoringSSL, which the no-OpenSSL policy (docs/07 rule 12) rules out. | Mediahro STATUS.md §3 |

## Local use

```bash
MEDIAHRO_WORK=K:/mw MEDIAHRO_TARGETS=x64 windows/build.sh dist
```

`MEDIAHRO_ONLY=a,b` runs only those recipes; `MEDIAHRO_REBUILD=a,b` ignores their stamps. Keep `MEDIAHRO_WORK` short: some upstream trees have deep paths.
