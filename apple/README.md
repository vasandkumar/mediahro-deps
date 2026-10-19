# apple sub-lane (lane B4b)

`apple/build.sh <out-dir>` builds every library in `../versions.json` that applies to Apple, with the flags in `../flags/` plus the Apple extras in `flags/`, as **dynamic `.framework`s**, assembles one **`.xcframework` per library** and packages two targets with `../scripts/package.py`:

| Target | Slices | Deployment |
|---|---|---|
| `ios-xcframeworks` | iOS `arm64`; iOS Simulator `arm64` + `x86_64` | iOS 16.0 |
| `macos-xcframeworks` | macOS `arm64` + `x86_64` (universal) | macOS 12.0 |

It runs on macOS with Xcode 26 (CI: the `apple` job of `.github/workflows/build.yml` on `macos-26`). Everything except the SDK and the build tools (meson, CMake, ninja, nasm, pkgconf; jinja2 for libplacebo's code generator) is built from pinned sources whose SHA-256 is verified before extraction.

## Archive layout

```
lib/<stem>.xcframework      one per library (FFmpeg, glib, OpenEXR... have several)
include/                    public headers (iOS: from ios-arm64; macOS: from macos-arm64)
licenses/<library>.txt      licence texts, including sub-dependencies
frameworks.json             framework stem -> library name in the manifest
manifest.json               written by scripts/package.py (licence scan input)
```

**Naming contract** (lane B1's podspec `vendored_frameworks` and `dart:ffi`): `lib/<stem>[.N…].dylib` becomes `<stem>.framework/<stem>`, e.g. `libmpv.framework/libmpv`, `libavcodec.framework/libavcodec`, `libplacebo.framework/libplacebo`, `libMoltenVK.framework/libMoltenVK`, `libvips.framework/libvips`, `libglib-2.framework/libglib-2`. Install names are `@rpath/<stem>.framework/<stem>` on iOS and `@rpath/<stem>.framework/Versions/A/<stem>` on macOS; each framework also carries an `@loader_path` rpath to its sibling frameworks. Frameworks are ad-hoc signed; the app build re-signs them with the real identity (signing is an owner task).

## Libraries

Every library in `versions.json` that applies to Apple; the build fails if one has no recipe. zlib, bzip2, libxml2 and libiconv come from the Apple SDK. Sources are fetched by `../scripts/sources.py`, which checks the SHA-256 (and the OpenPGP signature where upstream signs) before extracting.

Components compiled into another library get their own `build-info/` entry with `compiled_into`: glslang, SPIRV-Tools and SPIRV-Headers (into `libshaderc_shared`), SPIRV-Cross and cereal (into `libMoltenVK`; MoltenVK's CMake is pointed at the pinned trees, so it clones nothing), fast_float and glad (libplacebo), Vulkan-Headers (headers). SPIRV-Tools is left out of MoltenVK (debug disassembly only). OpenEXR compiles its vendored OpenJPH into OpenEXRCore.

Each library's `build-info/<name>.json` records the real configure options and the result of `../scripts/source_scan.py` over every slice; `package.py` turns them into `manifest.json` and the build fails if any GPL-only source was compiled.

## Policy notes

- **Licences:** no GPL code. FFmpeg uses `ffmpeg.common.flags` + `ffmpeg.apple.flags` (no `--enable-gpl/nonfree/version3`; the build fails if configure enables GPL, nonfree, version3, OpenSSL, GnuTLS, mbedTLS, libtls or postproc). mpv is `-Dgpl=false` with Lua and JavaScript off (checked in `config.h`). lcms2's GPL-3 `fastfloat`/`threaded` plugins are never built. Every library, LGPL or not, ships as its own dynamic framework.
- **TLS from the OS only, no OpenSSL anywhere.** FFmpeg uses SecureTransport (Security.framework) on iOS and macOS; the build fails if configure drops it. curl ≥ 8.15 dropped SecureTransport, so curl is built without TLS on both; HTTPS goes through the OS stack. libarchive uses CommonCrypto. libsmb2 uses its bundled NTLM/SMB3 primitives (encryption inventory, docs/07 rule 12).
- **Hardening:** `-D_FORTIFY_SOURCE=2 -fstack-protector-strong -fPIC -O2` everywhere, `-headerpad_max_install_names`, local symbols stripped. Clang CFI is not available for Apple dylibs (it needs whole-program LTO and does not cross dylib boundaries); arm64e pointer authentication is not used because third-party arm64e is not accepted for distribution. The hardened runtime is applied when the app signs the frameworks. PCRE2 is built without JIT (iOS forbids writable+executable memory).
- **GPU:** MoltenVK (no private Metal API) provides Vulkan; libplacebo links it directly (`vk-proc-addr`), and mpv is built with Vulkan, libplacebo and VideoToolbox→libplacebo interop. On macOS mpv also has cocoa + Swift for the `macvk` context (gpu-next on a `CAMetalLayer`). mpv's OpenGL / OpenGL ES paths are built too for the libmpv render API.

## Not built for Apple (ADR-017)

Crypto stays with the OS: SFTP on iOS/macOS uses SwiftNIO SSH over CryptoKit and FTPS / the CASTv2 sender run over Network.framework TLS sockets in the app, so libssh2 (Windows-only in `versions.json`) and openscreen-libcast (removed) are not part of the Apple archives, and libcurl has no TLS backend.

## Development

`MEDIAHRO_APPLE_SLICES` (subset of `ios-arm64 iossim-arm64 iossim-x86_64 macos-arm64 macos-x86_64`) and `MEDIAHRO_APPLE_ONLY` (subset of recipes in `recipes.sh`) narrow a run; a target is packaged only when all its slices were built. Logs per slice and library are in `build/apple/logs/`; a failing step prints its log tail.
