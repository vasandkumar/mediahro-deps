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
bins=""; avif_run=""; avif_expect=""
# AVIF_ONLY=1 or NO_TEXT=1 (a partial proof archive without libcld3/libbergamot) skips the text test.
NO_TEXT="${NO_TEXT:-${AVIF_ONLY:-}}"
if [ -z "$NO_TEXT" ]; then
  "$CXX" -std=c++17 -O2 "${extra[@]}" -I"$SRC/simd_utils" -o "$OUT/text_selftest" "$ROOT/android/selftest/text_selftest.cc" -ldl
  bins=text_selftest
fi
# AV1 encoder round trip (ADR-037): only when the archive carries libavif's headers; linked against the shipped libavif.so.
listing="$(tar -tzf "$ARCHIVE")"  # (grep -q on a pipe would trip pipefail)
if [[ "$listing" == *include/avif/avif.h* ]]; then
  inc="$(mktemp -d)"; tar -xzf "$ARCHIVE" -C "$inc" include/avif
  "$CXX" -std=c++17 -O2 -I"$inc/include" -o "$OUT/avif_selftest" "$ROOT/android/selftest/avif_selftest.cc" \
    -L"$OUT" -lavif -Wl,-rpath-link,"$OUT" -ldl
  rm -rf "$inc"; bins="$bins avif_selftest"
fi
# ONNX Runtime + the face models (ADR-046): only when the archive carries ORT's C API header and the .ort models.
ort_run=""; ort_expect=""
hdr="$(grep -m1 'onnxruntime_c_api\.h$' <<<"$listing" || true)"
if [ -n "$hdr" ] && [[ "$listing" == *share/mediahro/models/* ]]; then
  inc="$(mktemp -d)"; tar -xzf "$ARCHIVE" -C "$inc" "$hdr"
  "$CXX" -std=c++17 -O2 -I"$inc/$(dirname "$hdr")" -o "$OUT/ort_selftest" "$ROOT/android/selftest/ort_selftest.cc" \
    -L"$OUT" -lonnxruntime -Wl,-rpath-link,"$OUT" -ldl
  rm -rf "$inc"; bins="$bins ort_selftest"
  mkdir -p "$OUT/models"
  tar -xzf "$ARCHIVE" -C "$OUT" --wildcards 'share/mediahro/models/*.ort'
  mv "$OUT"/share/mediahro/models/*.ort "$OUT/models/"; rm -rf "$OUT/share"
  d_dir=/data/local/tmp/mediahro-b4a-selftest/$ABI; d_models=$d_dir/models
  ort_run="  adb -s <serial> shell mkdir -p $d_models
  adb -s <serial> push models/face_detection_yunet_2023mar.ort models/face_recognition_sface_2021dec_int8.ort $d_models/
  adb -s <serial> shell \"cd $d_dir && chmod 755 ort_selftest && LD_LIBRARY_PATH=$d_dir ./ort_selftest $d_models\""
  ort_expect="
ort_selftest (minimal ONNX Runtime, ORT-format YuNet and SFace int8), same rule: every line \"ok\", last line
\"selftest: PASS\", exit 0. The inference times are measured numbers for the PR; copy them back:

  ok   OrtGetApiBase / GetApi: 1.31.0
  ok   YuNet session: 12 outputs, input [1x3x640x640]
  ok   SFace session: 1 output, input [1x3x112x112]
  ok   YuNet outputs are finite float tensors: 12 tensors, first [...], <ms> ms
  ok   YuNet repeat run is bit-identical: <ms> ms
  ok   SFace embedding has 128 floats: [1x128], <ms> ms
  ok   SFace embedding is finite
  ok   SFace embedding is not zero: L2 norm ...
  ok   SFace same input gives the same embedding
  ok   SFace different inputs give different embeddings: cosine ...
  selftest: PASS
"
fi
archive_sha="$(sha256sum "$ARCHIVE" | cut -c1-64)"
d=/data/local/tmp/mediahro-b4a-selftest/$ABI
if [ -x "$OUT/avif_selftest" ]; then
  avif_run="  adb -s <serial> shell \"cd $d && chmod 755 avif_selftest && LD_LIBRARY_PATH=$d ./avif_selftest bench\""
  avif_expect="
avif_selftest (libaom encoder inside libavif.so, dav1d decoder), same rule: every line \"ok\", last line \"selftest: PASS\",
exit 0. The \"bench\" argument adds two 12 MP encodes at libavif speeds 6 and 8 (needs ~0.5 GB of RAM); copy the two
\"bench\" lines (size and time) back, they are the measured numbers for the size/speed note:

  libavif <version>, codecs: ...
  ok   AV1 encoder is aom: aom
  ok   aom decoder is not built in
  ok   AV1 decoder is dav1d: dav1d
  ok   dlopen libavif.so
  ok   avif* symbols exported
  ok   libaom symbols are not exported
  ok   8-bit 4:2:0 + alpha, quality 60, speed 6: <bytes> bytes, <ms> ms, PSNR >= 30 dB, alpha error <= 4/255
  ok   10-bit 4:4:4, quality 60, speed 6: ... PSNR >= 30 dB
  ok   lossless 8-bit 4:4:4 (identity matrix): ..., 0 mismatching samples
  ok   8-bit 4:2:0, 4 threads, speed 8: ... PSNR >= 30 dB
  ok   sweep 8-bit 4:2:0 q60 speed 0 ... and 10-bit 4:4:4, every speed 0..10 (22 lines, PSNR >= 28 dB; speed 0 is the slowest)
  ok   bench 12 MP (4000x3000) 8-bit 4:2:0 quality 60 speed 6, 4 threads: <bytes> bytes, <ms> ms
  ok   bench 12 MP (4000x3000) 8-bit 4:2:0 quality 60 speed 8, 4 threads: <bytes> bytes, <ms> ms
  selftest: PASS
"
fi
text_run=""; text_expect=""
if [ -z "$NO_TEXT" ]; then
  text_run="  adb -s <serial> shell \"cd $d && chmod 755 text_selftest && LD_LIBRARY_PATH=$d ./text_selftest\""
  text_expect="
text_selftest: every line must start with \"ok\", and the last line must be \"selftest: PASS\", exit status 0 (the numbers
may differ slightly):

  ok   dlopen libcld3.so"
fi
{
cat <<EOF
selftests for $ABI, libraries from $(basename "$ARCHIVE") (sha256 $archive_sha)

On the device, with the lock held (rule 9), from this folder:

  adb -s <serial> shell mkdir -p $d
  adb -s <serial> push $(cd "$OUT" && ls -- *.so $bins | tr '\n' ' ')$d/
$text_run
$avif_run
$ort_run
  adb -s <serial> shell rm -rf /data/local/tmp/mediahro-b4a-selftest
$text_expect
EOF
[ -z "$NO_TEXT" ] && cat <<'EOF'
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
printf '%s\n' "$avif_expect" "$ort_expect"
} > "$OUT/RUN.txt"
echo "selftest: staged $(ls "$OUT" | wc -l) files in $OUT; see RUN.txt"
