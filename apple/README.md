# apple sub-lane (lane B4b)

`apple/build.sh <out-dir>` builds every library in `../versions.json` that applies to Apple, with the flags in `../flags/` plus the Apple extras in `flags/`, as **dynamic `.framework`s**, assembles one **`.xcframework` per framework** and packages two targets with `../scripts/package.py`:

| Target | Slices | Deployment |
|---|---|---|
| `ios-xcframeworks` | iOS `arm64`; iOS Simulator `arm64` + `x86_64` | iOS 16.0 |
| `macos-xcframeworks` | macOS `arm64` + `x86_64` (universal) | macOS 12.0 |

It runs on macOS with Xcode 26 (CI: the `apple` job of `.github/workflows/build.yml` on `macos-26`). Everything except the SDK and the build tools (meson, CMake, ninja, nasm, pkgconf; jinja2 for libplacebo's code generator) is built from pinned sources whose SHA-256 is verified before extraction.

## Archive layout

```
Frameworks/<name>.xcframework  one per shipped dylib (FFmpeg, glib, OpenEXR... have several)
include/                       public headers (iOS: from ios-arm64; macOS: from macos-arm64)
licenses/<library>.txt         licence texts, including sub-dependencies
build-info/<library>.json      configure options, source-scan results, files / not_shipped
frameworks.json                framework name -> library name in the manifest
manifest.json                  written by scripts/package.py (licence scan input)
```

The build also writes `apple-sizes.md` (thinned iOS arm64 and macOS universal totals) next to the archives.

**Naming contract** (`packages/mediahro_ffi` `nativeLibraryFileName` and lane B1's engine loader): `lib<name>[.N…].dylib` becomes `<name>.framework/<name>`, e.g. `mpv.framework/mpv`, `vips.framework/vips`, `avcodec.framework/avcodec`, `placebo.framework/placebo`, `MoltenVK.framework/MoltenVK`, `glib-2.framework/glib-2`. Install names are `@rpath/<name>.framework/<name>` on iOS and `@rpath/<name>.framework/Versions/A/<name>` on macOS; each framework also carries an `@loader_path` rpath to its sibling frameworks. Frameworks are ad-hoc signed; the app build re-signs them with the real identity (signing is an owner task).

**What ships** (ADR-020): the dependency closure of the app's libraries — mpv and the FFmpeg libraries B1 opens for remuxing, plus every `NativeLibrary` in `packages/mediahro_ffi/lib/src/native/native_library.dart` (`APP_ROOTS` in `lib/frameworks.sh`). Dylibs a dependency builds but nothing needs (e.g. turbojpeg, raw_r, girepository, harfbuzz-subset) are listed under `not_shipped` in their build-info.

## Libraries

Every library in `versions.json` that applies to Apple; the build fails if one has neither a recipe nor an entry in `APPLE_NOT_BUILT` (`recipes.sh`: shaderc, SPIRV-Tools, SPIRV-Headers, libogg, FLAC, cgif — no user on Apple after ADR-020; lane B4a is removing `apple` from them in `versions.json`). zlib, bzip2, libxml2 and libiconv come from the Apple SDK. Sources are fetched by `../scripts/sources.py`, which checks the SHA-256 (and the OpenPGP signature where upstream signs) and applies `../patches/<name>/` before extracting.

Components compiled into another library get their own `build-info/` entry with `compiled_into`: glslang (static, into `placebo`), SPIRV-Cross and cereal (into `MoltenVK`; MoltenVK's CMake is pointed at the pinned trees, so it clones nothing), fast_float and glad (libplacebo), Vulkan-Headers (headers). OpenEXR compiles its vendored OpenJPH into OpenEXRCore.

Each library's `build-info/<name>.json` records the real configure options and the result of `../scripts/source_scan.py` over every slice; `package.py` turns them into `manifest.json` and the build fails if any GPL-only source was compiled.

## Size and speed (ADR-020)

Same set as Android (`android/build.sh`), mapped to Apple's toolchain:

- `-O2` on the decode / render / image hot paths; `-Os` for the libraries in `SIZE_LIBS` (`lib/common.sh`).
- ThinLTO (`-flto=thin`, compile and link) for every library except libvpx (installed as a static archive and wrapped).
- Section GC: `-ffunction-sections -fdata-sections` with `-Wl,-dead_strip`.
- `strip -x` on every shipped binary. ld64 / ld-prime has no `--icf=all`.
- FFmpeg from the shared `--disable-everything` + docs/04 component list, plus the VideoToolbox / AudioToolbox components in `../flags/ffmpeg.apple.flags`; configure fails on a component name it does not know.
- `MEDIAHRO_APPLE_MEASURE=1` runs one clean ios-arm64 build per switched-off optimisation (`MEDIAHRO_NO_LTO`, `MEDIAHRO_NO_GC`, `MEDIAHRO_ALL_O2`; stripping from the same build) and writes `apple-size-table.md`.

## Policy notes

- **Licences:** no GPL code. FFmpeg uses `ffmpeg.common.flags` + `ffmpeg.apple.flags` (no `--enable-gpl/nonfree/version3`; the build fails if configure enables GPL, nonfree, version3, OpenSSL, GnuTLS, mbedTLS, libtls or postproc). mpv is `-Dgpl=false` with Lua and JavaScript off (checked in `config.h`). lcms2's GPL-3 `fastfloat`/`threaded` plugins are never built. Every library, LGPL or not, ships as its own dynamic framework.
- **TLS from the OS only, no OpenSSL anywhere.** FFmpeg is configured with SecureTransport (Security.framework) and the build fails if configure drops it; the shared protocol list keeps HTTPS out of FFmpeg (it reaches FFmpeg through the app, ADR-017). curl ≥ 8.15 dropped SecureTransport, so curl has no TLS backend. libarchive uses CommonCrypto. libsmb2 uses its bundled NTLM/SMB3 primitives (encryption inventory, docs/07 rule 12).
- **Hardening:** `-D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIC` everywhere, `-headerpad_max_install_names`, local symbols stripped. Clang CFI is not available for Apple dylibs (it needs whole-program LTO and does not cross dylib boundaries); arm64e pointer authentication is not used because third-party arm64e is not accepted for distribution. The hardened runtime is applied when the app signs the frameworks. PCRE2 is built without JIT (iOS forbids writable+executable memory).
- **GPU:** MoltenVK (no private Metal API) provides Vulkan; libplacebo links it directly (`vk-proc-addr`), and mpv is built with Vulkan, libplacebo and VideoToolbox→libplacebo interop. On macOS mpv also has cocoa + Swift for the `macvk` context (gpu-next on a `CAMetalLayer`). mpv's OpenGL / OpenGL ES render API (B1's Apple bridge) is built with VideoToolbox→GL interop.

## Not built for Apple (ADR-017, ADR-018)

Crypto stays with the OS: SFTP on iOS/macOS uses SwiftNIO SSH over CryptoKit and FTPS / the CASTv2 sender run over Network.framework TLS sockets in the app, so libssh2 (Windows-only in `versions.json`) and openscreen-libcast (removed) are not part of the Apple archives, and libcurl has no TLS backend. VVC is decoded by FFmpeg's native decoder (vvdec removed, ADR-018).

## Development

`MEDIAHRO_APPLE_SLICES` (subset of `ios-arm64 iossim-arm64 iossim-x86_64 macos-arm64 macos-x86_64`) and `MEDIAHRO_APPLE_ONLY` (subset of recipes in `recipes.sh`) narrow a run; a target is packaged only when all its slices were built. Logs per slice and library are in `build/apple/logs/`; a failing step prints its log tail.
