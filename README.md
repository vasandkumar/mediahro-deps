# mediahro-deps

Build scripts for every native library Mediahro ships (Mediahro `docs/05` §10), per platform, with the exact licence-safe configure flags. Outputs are versioned, SHA-256-pinned release archives that the app fetches through its `deps.lock` (`tools/deps/fetch.py`). Scripts are MIT; each built library keeps its own licence, recorded in `versions.json` and in every archive's `manifest.json` and `licenses/`.

| Path | Purpose |
|---|---|
| `versions.json` | Upstream libraries: minimum and pinned versions, source SHA-256, licence, linking |
| `flags/` | Exact configure / meson flags (FFmpeg per platform, mpv, libplacebo, libvips) |
| `android/`, `apple/`, `windows/` | One B4 sub-lane each, entry point `build.sh <out-dir>` |
| `scripts/verify_flags.py` | Fails on GPL/nonfree flags, banned libraries, statically linked LGPL |
| `scripts/package.py` | Archive + `manifest.json` + SHA-256 for `deps.lock` |

## Targets

| Sub-lane | Targets | Toolchain |
|---|---|---|
| android | `android-arm64-v8a`, `android-armeabi-v7a`, `android-x86_64` | NDK r28+, API 29, `-Wl,-z,max-page-size=16384` |
| apple | `ios-xcframeworks` (device + simulator), `macos-xcframeworks` (arm64 + x86_64 until macOS 27) | Xcode 26, dynamic `.framework`s, MoltenVK |
| windows | `windows-x64`, `windows-arm64` | MSVC / clang-cl, `/guard:cf`, `/DYNAMICBASE` |

## Rules (Mediahro docs/09 §2)

- No GPL code in any artefact; LGPL only as shared libraries.
- FFmpeg without `--enable-gpl` / `--enable-nonfree` / `--enable-version3`; mpv with `-Dgpl=false`, Lua and JavaScript off.
- Never: exiv2, x264, x265, rubberband, libdvdcss / libdvdnav / libdvdread, libpostproc, smbclient, libcdio, frei0r; no libheif / libde265 on Windows; no OpenSSL (TLS from the OS).
- Hardened builds: `_FORTIFY_SOURCE=2`, stack protector, PIE, CFI / `/guard:cf` where supported.
- Sources are verified against the SHA-256 in `versions.json` before building; releases publish archives with `.sha256` files.

## Releases (built locally; no GitHub CI)

The owner turned GitHub CI off (2026-10-20), so `.github/workflows/build.yml` runs only when someone starts it by hand.
GitHub only hosts the release files. A release is built on the B4 lane's machine with no cache and uploaded as-is:

1. `android/build.sh dist` with `MEDIAHRO_CACHE` unset: a clean build of every ABI, which runs verify_flags, the source
   scan, check_elf, the symbol closure and package.py.
2. `scripts/sources.py fetch` plus `tar` gives `mediahro-deps-sources.tar`, the LGPL source offer: every pinned upstream
   source, `versions.json`, `keys/` and `patches/`.
3. `sha256sum` writes the `.sha256` files and `SHA256SUMS`.
4. `gh release create <tag> … --notes-file notes.md --prerelease` for a platform-suffixed tag (`v…-android.N`). The
   notes carry the build summary, the size of each archive and the licence-scan result.

Mediahro's `tools/deps/pin.py <tag>` re-downloads every archive and checks it against `SHA256SUMS` before pinning it in
`deps.lock`.
