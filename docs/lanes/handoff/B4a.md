# Handoff: Lane B4a (Sonnet 5.5), 2026-10-20

The Opus session for this lane is retired. You continue its work from the same folders.

## Read first
1. Mediahro `CLAUDE.md`, then `docs/lanes/README.md` rules 1–12 (app repo, on main). Most important:
   - **Android first.**
   - **No GitHub CI.** mediahro-deps' `build.yml` is manual-only (#13). Never start a workflow.
   - **Never touch the phone or an emulator.** The orchestrator runs device tests.
   - **One heavy build at a time.** WSL sees ~7 GB of the 16 GB PC.
   - **Nothing large on C:.**
   - The orchestrator owns `STATUS.md`, `CHANGELOG.md` and the workflows. Message it when a PR is ready or you're blocked.
2. ADRs 017–020 (deps, crypto, size), 033 (VID-041 filters), 034 (Tesseract + CLD3 + Bergamot, no ML Kit), 037 (C3: AV1 encoder).
3. **Model:** Sonnet 5.5. Hand genuinely hard native problems (Marian/sse2neon, linker, licence questions) to an Opus
   subagent with a self-contained prompt.

## Where this lane stands
- **Repo / folder:** `vasandkumar/mediahro-deps`, worktree `K:\Projects\mediahro-deps\.claude\worktrees\b4a-android-shared-180193`.
  - `…\b4a-rel` is a second, detached worktree for clean release builds.
  - `…\b4a-side` is a side worktree for small PRs. Never stash or switch branches in a worktree a running build reads from.
- **Branch:** `lane/b4a-armv7-simd`, head is the commit that adds this file, on top of `25caa92`. It's 1 commit ahead of main
  `057358e` and not pushed. It holds:
  - `patches/simd_utils/0001-armv7-builds.patch`: `_mm_set_epi64x`, the `float64x2_t` guard, and `vfmaq_f32`/`vfmaq_n_f32` →
    `vmlaq_*` without `__ARM_FEATURE_FMA`.
  - `patches/marian-dev/0003-armv7-vcvtnq.patch`: per-lane `lrintf`, round to nearest even.
  - `android/selftest/{text_selftest.cc,make.sh}`.
  - The orchestrator has approved both patches.
- **Merged on main:**
  - #12: FFmpeg `movtext`/`ccaption`, `lutrgb`/`blend`/`v360`, and `scripts/ffmpeg_components.py --configure`, which refuses all 33
    GPL-only components, `stereo3d` by name.
  - #13: build.yml manual-only, and the README "Releases" procedure.
  - #14: CLD3 + Bergamot (10 pins, `shims/`, Marian patches 0001/0002).
  - Earlier: #10 Tesseract/Leptonica and the libsmb2/libnfs patches.
- **Released:** `v2026.10.4` (Android-only pre-release, cancelled CI run). mediahro `deps.lock` pins `v2026.10.3-android.4`.

## In flight
1. **armeabi-v7a Bergamot rebuild + packaging** of `lane/b4a-armv7-simd` on the release work tree.
   - Script: `~/b4a/…/scratchpad/v7proof.sh`, run as `ONLY=bergamot-translator android/build.sh ~/b4a/out-v7 armeabi-v7a` with
     `MEDIAHRO_WORK=~/b4a/rel`.
   - Log: `~/b4a/log-v7.txt` (WSL). Finished when the log's last line is `mediahro-deps-android-armeabi-v7a.tar.gz.sha256` and
     `~/b4a/out-v7/mediahro-deps-android-armeabi-v7a.tar.gz` exists. Check with `tail -3 ~/b4a/log-v7.txt` and
     `ls -la ~/b4a/out-v7`.
   - **It was started as a background shell of the Opus session**, not with nohup/setsid, so it dies with that session. If
     `ps -eo pid,args | grep "[a]ndroid/build.sh"` shows nothing and the archive is missing, restart it detached:

         wsl -e bash -lc 'setsid nohup bash <scratchpad>/v7proof.sh > ~/b4a/v7proof.out 2>&1 &'

     or run the same `ONLY=… android/build.sh` line under setsid/nohup. Bergamot's jobs are capped by memory (~2 GB each, so 4 here).
2. **Self-test staging:** for each of arm64-v8a and armeabi-v7a, run `android/selftest/make.sh <abi> <archive> <out-dir>`
   (WSL, `ANDROID_NDK_HOME=~/b4a/android-ndk-r28c MEDIAHRO_WORK=~/b4a/rel`), with `<out-dir>` under this worktree's gitignored
   `build/selftest/<abi>`. arm64 archive: `~/b4a/rel/dist/mediahro-deps-android-arm64-v8a.tar.gz`; armv7: `~/b4a/out-v7/…`.
   Send the orchestrator the folder paths and the `RUN.txt` contents (adb push/run commands and the expected PASS lines).
   It runs them on the Samsung and replies.
   - The Opus session ran the arm64 test once on the device under the rule-9 lock, before the rule changed: PASS. Say so
     in the PR evidence.

## Next, in order
1. **Open the PR** for `lane/b4a-armv7-simd` once the orchestrator returns the armv7 device result. Evidence:
   - Before the patches, 48 Marian files failed on armv7; after them, 0.
   - The armv7 archive's check_elf and source scan.
   - The self-test results.
2. **After the merge: the clean release build** from main's merge commit, in the detached `b4a-rel` worktree
   (`git -C …\b4a-rel checkout --detach origin/main`).
   - `~/b4a/relbuild.sh`: edit its commit line. It builds all 3 ABIs into `~/b4a/rel/dist` with no cache, log
     `~/b4a/rel/build.log`. ~55 min per ABI.
   - x86_64 hasn't been built yet with CLD3/Bergamot (intgemm + ruy SGEMM). Watch for errors there.
   - If the out-of-memory killer stops it (exit 137), lower the parallelism.
3. **Release:**
   - `~/b4a/relpack.sh` builds `mediahro-deps-sources.tar` from exactly the 62 pinned Android sources (hashes re-checked),
     `versions.json`, `keys/`, `patches/` and `shims/`, then `SHA256SUMS`.
   - Then, from Git Bash, upload `~/b4a/rel/dist/*` (copy it to the worktree's `build/` first) with
     `gh release create v2026.10.5-android.1 --prerelease --title … --notes-file notes.md`. No workflow.
   - Notes: the commit, archive size and SHA-256 per ABI, stripped `.so` totals, the licence scan (0 GPL-only),
     "built locally, no cache", and the new contents:
     - FFmpeg names and VID-041 filters;
     - Tesseract 5.5.3 + Leptonica 1.87.0;
     - CLD3 + Bergamot;
     - the libsmb2 guest-session and libnfs errno patches;
     - the armv7 SIMD patches.
4. **deps.lock pin PR** in the app repo, worktree `K:\Projects\Mediahro\.claude\worktrees\b4a-deps-pinning`.
   - Make a fresh branch from origin/main (`lane/b4a-deps-v2026.10.4` is stale, 150+ behind; don't reuse it).
   - Run `python tools/deps/pin.py v2026.10.5-android.1`. Android targets only; keep the others as they are.
   - Put the release URL and the SHA-256s in the PR.
   - B1's VID-041 tests and C1's Tesseract/CLD3/Bergamot tests drop their skips after it merges.

## Patches and gotchas
- **Build root is WSL on H:** (`~/b4a`, virtual disk at `H:\WSL2\ubuntu`).
  - NDK `~/b4a/android-ndk-r28c`; tools in `~/b4a/env/bin` and `~/b4a/bin`.
  - Clean release tree `~/b4a/rel`. Its downloads were seeded from the v2026.10.4 source bundle, because videolan.org is
    unreachable here. `sources.py` still checks every SHA-256.
  - Dev tree `~/b4a/w-all`.
- **Git and paths:** git in WSL can't read these Windows worktrees. Run git from Git Bash, and builds in WSL via `/mnt/k/…`.
  In Git Bash, use `MSYS_NO_PATHCONV=1`.
- **Heredocs:** the shell layer turns `\\n`/`\\b` inside heredocs into real control characters. For multi-line edits, write a
  python script with the Write tool, or use the Edit tool.
- **FFmpeg:**
  - Component names are configure names (`movtext`, not `mov_text`).
  - `android/build.sh` runs `scripts/ffmpeg_components.py --configure "$SRC/ffmpeg/configure"` after configure. It fails on any
    missing requested component and on any GPL-only one.
  - Teletext isn't built: libzvbi has GPL-2-only files.
- **Marian:**
  - 0001 keeps the caller's compile flags (Marian used to replace them).
  - 0002 gives a revision without `.git`.
  - 0003 is the armv7 vcvtnq fix.
  - The shim compiles with bergamot's own `service.cpp` command, read from `ninja -t commands`.
- **libcld3/libbergamot** export only `mh_*` (`-fvisibility=hidden`, `--exclude-libs,ALL`).
- **Licence checks:** run them on every build: source scan, check_elf and the symbol closure, `verify_flags.py`.
- **Builds aren't proven yet** for armeabi-v7a (in flight) and x86_64 (next): CLD3/Bergamot and the FFmpeg filter changes.

## Queue after the release
1. **AV1 encoder for libavif** (C3's ADR-037): libaom or rav1e (BSD-2). Measure the size per ABI;
   `-DAVIF_CODEC_AOM=SYSTEM`. Notes: side-session-notes `b4a-next-release.md`.
2. **Build cache** (`lane/b4a-build-cache`, local `81f08ad`, not pushed): rebase onto `cmake_opts`/custom recipes and re-prove it.
3. **Apple/Windows:** Tesseract (B4c's `lane/b4c-windows-ocr` + `lane/b4a-tesseract-windows` `8a88392`), CLD3/Bergamot, and
   the `ffmpeg_components.py --configure` guard in `apple/` and `windows/`. Brief those lanes through the orchestrator.
4. The owner should delete the stray `K:\b4a_wsl_setup.sh`.
