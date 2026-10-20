#!/usr/bin/env bash
# Build android/selftest/text_selftest.cc for one ABI and stage it with an archive's shared libraries in <out-dir>,
# ready to run on an Android device (lane B4a, ADR-034). Lanes never touch the shared test device: the orchestrator
# runs the commands this writes to <out-dir>/RUN.txt under the device lock (Mediahro docs/lanes/README.md rule 9).
#
#   android/selftest/make.sh <abi> <archive.tar.gz> <out-dir>
#
# Needs ANDROID_NDK_HOME and $MEDIAHRO_WORK/src/simd_utils (from a build of the same sources).
set -euo pipefail
ABI="$1" ARCHIVE="$2" OUT="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:?}"; SRC="${MEDIAHRO_WORK:-$ROOT/build/android}/src"
T="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
case "$ABI" in
  arm64-v8a) CXX="$T/aarch64-linux-android29-clang++"; extra=(-DARM -DSSE -DFMA) ;;
  armeabi-v7a) CXX="$T/armv7a-linux-androideabi29-clang++"; extra=(-mfpu=neon -DARM -DSSE -DFMA) ;;
  x86_64) CXX="$T/x86_64-linux-android29-clang++"; extra=() ;;
  *) echo "selftest: unknown ABI $ABI" >&2; exit 2 ;;
esac
rm -rf "$OUT"; mkdir -p "$OUT"
tar -xzf "$ARCHIVE" -C "$OUT" --wildcards 'lib/*.so'
mv "$OUT"/lib/*.so "$OUT/"; rmdir "$OUT/lib"
"$CXX" -std=c++17 -O2 "${extra[@]}" -I"$SRC/simd_utils" -o "$OUT/text_selftest" "$ROOT/android/selftest/text_selftest.cc" -ldl
archive_sha="$(sha256sum "$ARCHIVE" | cut -c1-64)"
d=/data/local/tmp/mediahro-b4a-selftest/$ABI
cat > "$OUT/RUN.txt" <<EOF
text_selftest for $ABI, libraries from $(basename "$ARCHIVE") (sha256 $archive_sha)

On the device, with the lock held (rule 9), from this folder:

  adb -s <serial> shell mkdir -p $d
  adb -s <serial> push $(cd "$OUT" && ls -- *.so text_selftest | tr '\n' ' ')$d/
  adb -s <serial> shell "cd $d && chmod 755 text_selftest && LD_LIBRARY_PATH=$d ./text_selftest"
  adb -s <serial> shell rm -rf /data/local/tmp/mediahro-b4a-selftest

Expected (the numbers may differ slightly; every line must start with "ok", and the last line must be "selftest: PASS",
exit status 0):

  ok   dlopen libcld3.so
  ok   mh_cld3_* symbols
  ok   mh_cld3_new(0, 512)
  ok   mh_cld3_find: got en (p=1.000, reliable=1), want en
  ok   mh_cld3_find: got de (p=0.999, reliable=1), want de
  ok   dlopen libbergamot.so
  ok   mh_bergamot_* symbols
  ok   mh_bergamot_new(0)
  ok   mh_bergamot_load(missing model) refused: NULL with message "Errno 2: No such file or directory"
  ok   simd_utils exp_ps vs libm: max relative error 1.15e-07 (limit 1e-6)
  ok   simd_utils log_ps vs libm: max absolute error 4.77e-07 (limit 1e-6)
  selftest: PASS
EOF
echo "selftest: staged $(ls "$OUT" | wc -l) files in $OUT; see RUN.txt"
