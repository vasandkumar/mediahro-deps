# android sub-lane (lane B4a)

`android/build.sh <out-dir> [abi ...]` builds every library in `../versions.json` that applies to
Android with the flags in `../flags/`, stages `lib/`, `include/`, `licenses/`, `build-info/` and runs
`../scripts/package.py` once per ABI:

| Archive | ABI | Toolchain |
|---|---|---|
| `mediahro-deps-android-arm64-v8a.tar.gz` | arm64-v8a | NDK r28c (28.2.13676358), API 29 |
| `mediahro-deps-android-armeabi-v7a.tar.gz` | armeabi-v7a | NDK r28c, API 29 |
| `mediahro-deps-android-x86_64.tar.gz` | x86_64 | NDK r28c, API 29 |

Host requirements (Linux x86_64): python3 with jinja2, meson (`requirements-build.txt`), ninja, cmake,
make, autotools, pkg-config, nasm, gperf, a host C compiler, and the NDK in `ANDROID_NDK_HOME`.
CI installs exactly these (`.github/workflows/build.yml`, job `android`).

## What the build guarantees (checked before packaging)

- **Sources**: every tarball is verified (SHA-256 from `versions.json`, OpenPGP signature where upstream
  signs) before it is extracted (`scripts/sources.py`). Meson never downloads (`--wrap-mode nodownload`).
- **Licences** (Mediahro docs/09 §2): no GPL code — `scripts/source_scan.py` lists the sources linked
  into each shipped library and fails on GPL-only files; LGPL libraries are shared objects; no OpenSSL,
  BoringSSL, mbedTLS or GnuTLS (nothing links a TLS library; curl is built without TLS).
- **ELF** (`check_elf`): every `.so` has 16 KB-aligned LOAD segments (64-bit ABIs; on armeabi-v7a, where
  devices use 4 KB pages, only the NDK's own `libc++_shared.so` is 4 KB-aligned), RELRO + BIND_NOW, a
  non-executable stack, no text relocations, an unversioned SONAME equal to its file name (Gradle only
  packages `lib*.so`), and needs only libraries in the archive or NDK system libraries.
- **Hardening**: `-D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection`, PIC,
  `-z relro -z now -z noexecstack`; control-flow integrity in hardware: BTI + PAC on arm64-v8a
  (`-mbranch-protection=standard`), CET on x86_64 (`-fcf-protection=full`). Clang's software CFI
  (`-fsanitize=cfi`) is not used: it needs LTO across one DSO and does not cover calls between the
  shared libraries that make up this archive. armeabi-v7a has no hardware CFI.
- **Size** (ADR-020: features are never cut, speed budgets never move):
  - FFmpeg starts from `--disable-everything` and enables only the docs/04 components in
    `flags/ffmpeg.common.flags`; a misspelt name fails the build.
  - ThinLTO (`-flto=thin`) on every compile and link, except libvpx (assembly, static into libavcodec).
  - Section GC (`-ffunction-sections -fdata-sections`, `-Wl,--gc-sections`) and identical-code folding
    (`-Wl,--icf=all`).
  - `-O2` for decode and render paths (FFmpeg, dav1d, libplacebo, mpv, libass/freetype/harfbuzz/fribidi,
    image codecs, whisper, Tesseract); `-Os` for the rest (`SIZE_LIBS`, including Leptonica).
  - `llvm-strip --strip-unneeded` on every shipped `.so`; one `libc++_shared.so`.
  - To measure one optimisation, switch it off: `MEDIAHRO_NO_LTO=1`, `MEDIAHRO_NO_ICF=1`, `MEDIAHRO_NO_GC=1`,
    `MEDIAHRO_ALL_O2=1`.
- **C++**: `libc++_shared.so` from the NDK is in the archive (the NDK's recommendation when several
  shared libraries use C++).

## Archive layout

    lib/*.so            shared libraries (stripped; build IDs kept)
    include/            headers for ffigen / the engine plugin
    licenses/<name>.txt upstream licence texts
    build-info/<name>.json  configure line, produced files, source-scan result per library
    manifest.json       read by Mediahro's tools/licence_scan

## Not built for Android (by design, ADR-017: crypto stays with the OS)

- `libssh2`: Windows only (WinCNG). On Android SFTP uses sshj over JCA behind `SftpFacade`; FTPS runs over
  `TlsSocketFacade` (SSLSocket), so curl has no TLS backend here.
- `openscreen-libcast`: removed everywhere; the Dart CASTv2 sender over OS TLS sockets replaces it.
- Install size (docs/11 §5, `not_built_by_design` in versions.json): `shaderc`, `spirv-tools`, `spirv-headers`
  (libplacebo links a static glslang without its optimiser instead), `vvdec` (mpv decodes VVC with FFmpeg's native
  decoder), `flac` / `libogg` (FFmpeg decodes FLAC and Ogg), `cgif` (libvips has no permissive quantiser; GIF export
  uses FFmpeg). Installed by their build systems but neither linked nor loaded through FFI, so not staged:
  SPIRV-Tools-shared, girepository, gthread, pcre2-posix, parakeet, raw_r, webpdecoder (`DROP_LIBS`).
- `moltenvk`, `zlib` (OS zlib), `vulkan-loader`, `spirv-cross`: not Android libraries.

## Runtime notes for the engine (B1)

- fontconfig looks in `/system/fonts`; set `FONTCONFIG_FILE` / `FONTCONFIG_PATH` and a writable cache
  directory from the app before the first libass use.
- libnfs 8.0 is built without its multithreading layer (it does not compile against bionic): use one
  `nfs_context` per isolate/thread (lane B2).
- Tesseract (SUB-051 OCR fallback, ADR-025 §5): `libtesseract.so` with its C API (`include/tesseract/capi.h`) over
  `libleptonica.so`. No traineddata ships: download `<lang>.traineddata` (tessdata_fast / tessdata_best) and pass its
  directory to `TessBaseAPIInit3`. The legacy engine is kept (OSD script detection needs it). No OpenMP: one
  `TessBaseAPI` per isolate. Leptonica reads JPEG, TIFF and WebP; no PNG or GIF (pass pixels with `TessBaseAPISetImage`).
- CLD3 (language identification, ADR-034): `libcld3.so` exports only `include/mediahro_cld3.h` (`mh_cld3_*`, lane C1's
  shim in `../shims/cld3`). The model is compiled in. protobuf-lite 21.12 is linked statically and hidden.
- Bergamot (SUB-053 translation, ADR-034): `libbergamot.so` exports only `include/mediahro_bergamot.h` (`mh_bergamot_*`,
  `../shims/bergamot`). Marian is CPU only: ruy (int8 and SGEMM) with simd_utils on ARM, and intgemm (run-time ISA
  dispatch) with ruy SGEMM on x86_64, so there is no BLAS. It links the shipped `libpcre2-8.so`. No models ship: the app
  downloads a language pair's model, vocabulary and shortlist after consent and passes their paths in the YAML config to
  `mh_bergamot_load`.
- libvulkan, libEGL, libGLESv2, libmediandk, libaaudio, libOpenSLES and libandroid are NDK system libraries.

## Development

    MEDIAHRO_WORK=~/work ANDROID_NDK_HOME=~/android-ndk-r28c android/build.sh ~/out arm64-v8a
    ONLY="ffmpeg mpv" ...     # rebuild named recipes
    SKIP="vvdec" ...          # leave recipes out

Stamps in `$MEDIAHRO_WORK/<abi>/stamps` skip libraries whose source and configure arguments are unchanged.
