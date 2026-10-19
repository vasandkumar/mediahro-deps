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
- **ELF** (`check_elf`): every `.so` has 16 KB-aligned LOAD segments, RELRO + BIND_NOW, a
  non-executable stack, no text relocations, an unversioned SONAME equal to its file name (Gradle only
  packages `lib*.so`), and needs only libraries in the archive or NDK system libraries.
- **Hardening**: `-D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection`, PIC,
  `-z relro -z now -z noexecstack`; control-flow integrity in hardware: BTI + PAC on arm64-v8a
  (`-mbranch-protection=standard`), CET on x86_64 (`-fcf-protection=full`). Clang's software CFI
  (`-fsanitize=cfi`) is not used: it needs LTO across one DSO and does not cover calls between the
  shared libraries that make up this archive. armeabi-v7a has no hardware CFI.
- **C++**: `libc++_shared.so` from the NDK is in the archive (the NDK's recommendation when several
  shared libraries use C++).

## Archive layout

    lib/*.so            shared libraries (stripped; build IDs kept)
    include/            headers for ffigen / the engine plugin
    licenses/<name>.txt upstream licence texts
    build-info/<name>.json  configure line, produced files, source-scan result per library
    manifest.json       read by Mediahro's tools/licence_scan

## Not built for Android (see Mediahro STATUS.md §3)

- `libssh2`: needs a crypto backend; Android has no OS crypto API in the NDK and the policy excludes
  OpenSSL / mbedTLS (SFTP, NET-004).
- `openscreen-libcast`: Chromium GN build with BoringSSL (CAST-001 FOSS flavour).
- `moltenvk`, `zlib` (OS zlib), `vulkan-loader`, `spirv-cross`: not Android libraries.

## Runtime notes for the engine (B1)

- fontconfig looks in `/system/fonts`; set `FONTCONFIG_FILE` / `FONTCONFIG_PATH` and a writable cache
  directory from the app before the first libass use.
- libnfs 8.0 is built without its multithreading layer (it does not compile against bionic): use one
  `nfs_context` per isolate/thread (lane B2).
- libvulkan, libEGL, libGLESv2, libmediandk, libaaudio, libOpenSLES and libandroid are NDK system libraries.

## Development

    MEDIAHRO_WORK=~/work ANDROID_NDK_HOME=~/android-ndk-r28c android/build.sh ~/out arm64-v8a
    ONLY="ffmpeg mpv" ...     # rebuild named recipes
    SKIP="vvdec" ...          # leave recipes out

Stamps in `$MEDIAHRO_WORK/<abi>/stamps` skip libraries whose source and configure arguments are unchanged.
