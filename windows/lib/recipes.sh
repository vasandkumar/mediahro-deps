# Per-library build recipes for windows/build.sh (sourced).
# Each r_<name> runs in a subshell with B (its build dir), T, PREFIX, ARCH set,
# installs into $PREFIX, records licences with `license` and what it produced
# with `built`. Order matters: dependencies first.
# shellcheck shell=bash

RECIPES="zlib bzip2 xz zstd expat
vulkan_headers vulkan_loader spirv_cross shaderc
lcms2 dav1d libogg opus flac libvpx libopenmpt ffmpeg
freetype fribidi harfbuzz fontconfig libass libplacebo uchardet win_iconv libjpeg_turbo libudfread libbluray mpv
libspng libwebp libdeflate libtiff imath openexr cgif highway brotli libjxl libavif libraw libexif glib libvips
libssh2 curl libsmb2 libnfs libarchive libebur128 chromaprint whisper_cpp vvdec"

# ------------------------------------------------------------ compression

r_zlib() {
  local s; s=$(fetch zlib)
  cmake_build "$s" "$B" -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_STATIC=OFF -DZLIB_BUILD_SHARED=ON -DZLIB_INSTALL_COMPAT_DLL=OFF
  # Same import library under the name MSVC-style consumers (FFmpeg -lz) expect.
  cp -f "$PREFIX/lib/z.lib" "$PREFIX/lib/zlib.lib"
  license zlib "$s/LICENSE"
  built zlib
}

r_bzip2() {
  local s; s=$(fetch bzip2)
  cmake_build "$HERE/cmake/bzip2" "$B" -DBZIP2_SRC="$(w "$s")"
  license bzip2 "$s/LICENSE"
  built bzip2
}

r_xz() {
  local s; s=$(fetch xz)
  cmake_build "$s" "$B" -DXZ_NLS=OFF -DXZ_DOC=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
    -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF -DXZ_TOOL_SYMLINKS_LZMA=OFF
  license xz "$s/COPYING" "$s/COPYING.0BSD"
  built xz
}

r_zstd() {
  local s; s=$(fetch zstd)
  cmake_build "$s/build/cmake" "$B" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF \
    -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_SHARED=ON -DZSTD_MULTITHREAD_SUPPORT=ON -DZSTD_LEGACY_SUPPORT=OFF
  license zstd "$s/LICENSE"
  built zstd
}

r_expat() {
  local s; s=$(fetch expat)
  cmake_build "$s" "$B" -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_FUZZERS=OFF -DEXPAT_SHARED_LIBS=ON -DEXPAT_MSVC_STATIC_CRT=OFF
  license expat "$s/COPYING"
  built expat
}

# ------------------------------------------------------- Vulkan / SPIR-V

r_vulkan_headers() {
  local s; s=$(fetch vulkan-headers)
  cmake_build "$s" "$B" -DVULKAN_HEADERS_ENABLE_TESTS=OFF -DVULKAN_HEADERS_ENABLE_MODULE=OFF
  license vulkan-headers "$s/LICENSE.md"
  built vulkan-headers
}

# Import library only: vulkan-1.dll belongs to the GPU driver install and is
# delay-loaded by libplacebo and mpv (stage_target does not ship it).
r_vulkan_loader() {
  local s; s=$(fetch vulkan-loader)
  # USE_MASM=OFF: only the import library is used, and the arm64 armasm
  # sources need cl.exe preprocessing that a clang-cl toolchain does not do.
  cmake_build "$s" "$B" -DBUILD_TESTS=OFF -DBUILD_WERROR=OFF -DUPDATE_DEPS=OFF -DUSE_MASM=OFF \
    -DVulkanHeaders_DIR="$(w "$PREFIX/share/cmake/VulkanHeaders")"
  license vulkan-loader "$s/LICENSE.txt"
  built vulkan-loader
}

r_spirv_cross() {
  local s; s=$(fetch spirv-cross)
  cmake_build "$s" "$B" -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_STATIC=OFF -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_ENABLE_MSL=OFF -DSPIRV_CROSS_ENABLE_CPP=OFF \
    -DSPIRV_CROSS_ENABLE_REFLECT=ON -DSPIRV_CROSS_ENABLE_HLSL=ON -DSPIRV_CROSS_ENABLE_GLSL=ON \
    -DSPIRV_CROSS_ENABLE_C_API=ON -DSPIRV_CROSS_ENABLE_UTIL=ON
  license spirv-cross "$s/LICENSE"
  built spirv-cross
}

# shaderc_shared.dll with glslang, SPIRV-Tools and SPIRV-Headers (revisions
# from shaderc's DEPS) linked in statically.
r_shaderc() {
  local s g t h; s=$(fetch shaderc); g=$(fetch glslang); t=$(fetch spirv-tools); h=$(fetch spirv-headers)
  cmake_build "$s" "$B" -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_GLSLANG_DIR="$(w "$g")" -DSHADERC_SPIRV_TOOLS_DIR="$(w "$t")" -DSHADERC_SPIRV_HEADERS_DIR="$(w "$h")" \
    -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_EXECUTABLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_SHARED_CRT=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF \
    -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_SKIP_TESTS=ON -DSPIRV_WERROR=OFF -DSPIRV_TOOLS_BUILD_STATIC=ON \
    -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF -DENABLE_CTEST=OFF -DENABLE_OPT=ON
  license shaderc "$s/LICENSE"
  license glslang "$g/LICENSE.txt"
  license spirv-tools "$t/LICENSE"
  license spirv-headers "$h/LICENSE"
  built shaderc glslang spirv-tools spirv-headers
}

# ------------------------------------------------------------ codecs

r_lcms2() {
  local s; s=$(fetch lcms2)
  # fastfloat / threaded plugins are GPL-3.0: never built.
  meson_build "$s" "$B" -Dtests=disabled -Djpeg=disabled -Dtiff=disabled -Dutils=false -Dfastfloat=false -Dthreaded=false
  license lcms2 "$s/LICENSE"
  built lcms2
}

r_dav1d() {
  local s; s=$(fetch dav1d)
  meson_build "$s" "$B" -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false -Dxxhash_muxer=disabled
  license dav1d "$s/COPYING"
  built dav1d
}

r_libogg() {
  local s; s=$(fetch libogg)
  cmake_build "$s" "$B" -DINSTALL_DOCS=OFF
  license libogg "$s/COPYING"
  built libogg
}

r_opus() {
  local s neon=(); s=$(fetch opus)
  # NEON is architectural on arm64. Opus only presumes it when the processor
  # is spelled "aarch64" (CMake says ARM64 here); otherwise it compiles ARM32
  # runtime probes (__emit of ARM32 opcodes) that clang-cl rejects.
  [ "$ARCH" = arm64 ] && neon=(-DOPUS_PRESUME_NEON=ON -DOPUS_MAY_HAVE_NEON=OFF)
  cmake_build "$s" "$B" "${neon[@]}" -DOPUS_BUILD_SHARED_LIBRARY=ON -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON -DOPUS_STATIC_RUNTIME=OFF
  license opus "$s/COPYING"
  built opus
}

r_flac() {
  local s; s=$(fetch flac)
  cmake_build "$s" "$B" -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF \
    -DWITH_OGG=ON -DBUILD_CXXLIBS=ON -DWITH_STACK_PROTECTOR=OFF -DWITH_FORTIFY_SOURCE=OFF
  license flac "$s/COPYING.Xiph"
  built flac
}

# libvpx has no shared-library support for MSVC: build vpxmd.lib with its
# MSBuild projects (cl.exe; CFG through the CL environment variable), then
# link vpx.dll from it with upstream's export lists.
r_libvpx() {
  local s vs out f; s=$(fetch libvpx)
  vs=${VisualStudioVersion%%.*}
  rm -rf "$B"; mkdir -p "$B"; cd "$B"
  export CL="-guard:cf -GS -Gy -Zc:inline"
  local as=(); [ "$ARCH" = x64 ] && as=(--as=nasm)
  "$s/configure" --target="$VPX_ARCH-win64-vs$vs" "${as[@]}" --disable-examples --disable-tools --disable-docs \
    --disable-unit-tests --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --disable-install-bins --disable-install-srcs
  make -j"$JOBS"
  out=$(find "$B" -name vpxmd.lib -path "*Release*" | head -1)
  [ -n "$out" ] || { echo "vpxmd.lib not produced"; return 1; }
  { echo "EXPORTS"; cat "$s"/vpx/exports_* "$s"/vp8/exports_* "$s"/vp9/exports_* | tr -d '\r' |
      awk '$1 == "text" { print "  " $2 } $1 == "data" { print "  " $2 " DATA" }' | sort -u; } > vpx.def
  link.exe -nologo -DLL -OUT:"$(w "$PREFIX/bin/vpx.dll")" -IMPLIB:"$(w "$PREFIX/lib/vpx.lib")" -DEF:vpx.def \
    -MACHINE:"$VS_PLATFORM" $HARDEN_LDFLAGS "$(w "$out")"
  mkdir -p "$PREFIX/include/vpx"
  for f in "$s"/vpx/*.h; do cp "$f" "$PREFIX/include/vpx/"; done
  cat > "$PREFIX/lib/pkgconfig/vpx.pc" <<PC
prefix=$(w "$PREFIX")
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: vpx
Description: WebM Project VPx codec implementation
Version: $(pin libvpx version)
Libs: -L\${libdir} -lvpx
Cflags: -I\${includedir}
PC
  license libvpx "$s/LICENSE" "$s/PATENTS"
  built libvpx
}

r_libopenmpt() {
  local s; s=$(fetch libopenmpt)
  cmake_build "$HERE/cmake/libopenmpt" "$B" -DOPENMPT_SRC="$(w "$s")"
  license libopenmpt "$s/LICENSE"
  built libopenmpt
}

# FFmpeg: LGPL-2.1+ (no --enable-gpl/nonfree/version3), shared, flags from
# flags/ffmpeg.common.flags + flags/ffmpeg.windows.flags, clang-cl via the
# msvc toolchain; arm64 assembly through gas-preprocessor + armasm64.
r_ffmpeg() {
  local s args=() cross=() cc; s=$(fetch ffmpeg)
  rm -rf "$B"; mkdir -p "$B"; cd "$B"
  local f help; help=$("$s/configure" --help)
  while IFS= read -r f; do
    # A --disable-X for a component this FFmpeg no longer has (libpostproc
    # was removed in 8.0) is a no-op; configure would reject it.
    if [[ $f == --disable-* ]] && ! grep -q -- "${f#--disable-}" <<<"$help"; then
      echo "ffmpeg: dropping $f (not an option of this FFmpeg)"; continue
    fi
    args+=("$f")
  done < <(flags_of "$ROOT/flags/ffmpeg.common.flags"; flags_of "$ROOT/flags/ffmpeg.windows.flags")
  cc="clang-cl -target $CLANG_TARGET"
  local host=(--host-cc=clang-cl --host-ld="$s/compat/windows/mslink")
  if [ "$ARCH" = arm64 ]; then
    # Table generators run on the x64 build machine: x64 CRT/SDK libraries
    # ahead of vcvars' arm64 LIB, and an x64 image.
    local sdk; sdk=$(cygpath -m "${WindowsSdkDir}Lib/${WindowsSDKVersion}"); sdk=${sdk%/}
    cross=(--enable-cross-compile)
    host=(--host-cc="clang-cl -target x86_64-pc-windows-msvc" --host-ld="$s/compat/windows/mslink"
          --host-ldflags="-MACHINE:X64 -LIBPATH:$(cygpath -m "$VCToolsInstallDir")lib/x64 -LIBPATH:$sdk/ucrt/x64 -LIBPATH:$sdk/um/x64")
  fi
  # Host tools (table generators) link with MSVC link.exe like the libraries;
  # clang-cl from the LLVM release would otherwise drive lld-link.
  "$s/configure" "${args[@]}" "${cross[@]}" --arch="$FF_ARCH" --cc="$cc" --cxx="$cc" \
    "${host[@]}" \
    --pkg-config=pkgconf --prefix="$(w "$PREFIX")" \
    --extra-cflags="-MD $HARDEN_CFLAGS -I$(w "$PREFIX/include")" --extra-cxxflags="-MD $HARDEN_CFLAGS -I$(w "$PREFIX/include")" \
    --extra-ldflags="$HARDEN_LDFLAGS -LIBPATH:$(w "$PREFIX/lib")" \
    || { tail -80 ffbuild/config.log; return 1; }
  grep -E "^(License|Enabled hwaccels|External libraries)" -A3 ffbuild/config.log 2>/dev/null | head -20 || true
  make -j"$JOBS"
  make install
  # The msvc toolchain installs import libraries next to the DLLs.
  mv -f "$PREFIX"/bin/av*.lib "$PREFIX"/bin/sw*.lib "$PREFIX/lib/"
  license ffmpeg "$s/COPYING.LGPLv2.1" "$s/LICENSE.md"
  built ffmpeg
}

# ------------------------------------------------------ text and rendering

r_freetype() {
  local s; s=$(fetch freetype)
  meson_build "$s" "$B" -Dzlib=system -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled -Dharfbuzz=disabled -Dtests=disabled
  license freetype "$s/LICENSE.TXT" "$s/docs/FTL.TXT"
  built freetype
}

r_fribidi() {
  local s; s=$(fetch fribidi)
  meson_build "$s" "$B" -Ddocs=false -Dbin=false -Dtests=false
  license fribidi "$s/COPYING"
  built fribidi
}

r_harfbuzz() {
  local s; s=$(fetch harfbuzz)
  meson_build "$s" "$B" -Dfreetype=enabled -Dgdi=enabled -Ddirectwrite=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dpng=disabled -Dzlib=disabled -Dgraphite2=disabled \
    -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
    -Dutilities=disabled -Dbenchmark=disabled -Dcpp_std=c++17  # MSVC STL needs C++14+; harfbuzz defaults to c++11
  license harfbuzz "$s/COPYING"
  built harfbuzz
}

# gperf (GPL) is replaced by patches/fontconfig's generator for fcobjshash.h.
r_fontconfig() {
  local s; s=$(fetch fontconfig)
  meson_build "$s" "$B" -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled \
    -Diconv=disabled -Dxml-backend=expat -Dfontations=disabled
  license fontconfig "$s/COPYING"
  built fontconfig
}

r_libass() {
  local s; s=$(fetch libass)
  meson_build "$s" "$B" -Dfontconfig=enabled -Ddirectwrite=enabled -Dcoretext=disabled -Dasm=enabled \
    -Dlibunibreak=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
  license libass "$s/COPYING"
  built libass
}

r_libplacebo() {
  local s ff args=() f; s=$(fetch libplacebo); ff=$(fetch fast_float)
  # GitHub tag archives have no submodules; libplacebo uses fast_float's headers.
  mkdir -p "$s/3rdparty/fast_float"; cp -r "$ff/include" "$s/3rdparty/fast_float/"
  local fl; fl=$(shared_meson_flags "$s" "$ROOT/flags/libplacebo.flags"; flags_of "$HERE/flags/libplacebo.flags")
  mapfile -t args <<<"$fl"
  [ ${#args[@]} -ge 5 ] || { echo "libplacebo: flag list empty"; return 1; }
  MESON_EXTRA_LDFLAGS="-DELAYLOAD:vulkan-1.dll delayimp.lib" \
    meson_build "$s" "$B" "${args[@]}" -Dvulkan-registry="$(w "$PREFIX/share/vulkan/registry/vk.xml")"
  license libplacebo "$s/LICENSE"
  license fast_float "$ff/LICENSE-MIT"
  built libplacebo fast_float
}

r_uchardet() {
  local s; s=$(fetch uchardet)
  cmake_build "$s" "$B" -DBUILD_BINARY=OFF -DBUILD_STATIC=OFF
  license uchardet "$s/COPYING"
  built uchardet
}

r_win_iconv() {
  local s; s=$(fetch win-iconv)
  cmake_build "$s" "$B" -DWIN_ICONV_BUILD_STATIC=OFF -DWIN_ICONV_BUILD_EXECUTABLE=OFF -DWIN_ICONV_BUILD_TEST=OFF
  license win-iconv "$s/readme.txt"
  built win-iconv
}

r_libjpeg_turbo() {
  local s; s=$(fetch libjpeg-turbo)
  cmake_build "$s" "$B" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=ON -DWITH_JAVA=OFF \
    -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DREQUIRE_SIMD=ON
  license libjpeg-turbo "$s/LICENSE.md" "$s/README.ijg"
  built libjpeg-turbo
}

r_libudfread() {
  local s; s=$(fetch libudfread)
  meson_build "$s" "$B" -Denable_examples=false
  license libudfread "$s/COPYING"
  built libudfread
}

# Unencrypted BDMV only (VID-007): no AACS/BD+ libraries, no BD-J (Java).
r_libbluray() {
  local s; s=$(fetch libbluray)
  meson_build "$s" "$B" -Dbdj_jar=disabled -Denable_tools=false -Denable_devtools=false -Denable_examples=false \
    -Denable_docs=false -Dlibxml2=disabled -Dfreetype=enabled -Dfontconfig=enabled -Dembed_udfread=false
  license libbluray "$s/COPYING"
  built libbluray
}

# libmpv (LGPL: -Dgpl=false, no Lua/JS); flags/mpv.flags + windows/flags/mpv.flags.
r_mpv() {
  local s args=() f; s=$(fetch mpv)
  local fl; fl=$(shared_meson_flags "$s" "$ROOT/flags/mpv.flags"; flags_of "$HERE/flags/mpv.flags")
  mapfile -t args <<<"$fl"
  [ ${#args[@]} -ge 5 ] || { echo "mpv: flag list empty"; return 1; }
  MESON_EXTRA_LDFLAGS="-DELAYLOAD:vulkan-1.dll delayimp.lib" meson_build "$s" "$B" "${args[@]}"
  grep -q "gpl.*false\|GPL.*disabled\|LGPL" "$B/meson-logs/meson-log.txt" || true
  license mpv "$s/LICENSE.LGPL" "$s/Copyright"
  built mpv
}

# --------------------------------------------------------------- images

r_libspng() {
  local s; s=$(fetch libspng)
  cmake_build "$s" "$B" -DSPNG_SHARED=ON -DSPNG_STATIC=OFF -DBUILD_EXAMPLES=OFF
  # Upstream writes libspng.pc only on non-Windows hosts.
  cat > "$PREFIX/lib/pkgconfig/libspng.pc" <<PC
prefix=$(w "$PREFIX")
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libspng
Description: PNG decoding and encoding library
Version: $(pin libspng version)
Requires.private: zlib
Libs: -L\${libdir} -lspng
Cflags: -I\${includedir}
PC
  license libspng "$s/LICENSE"
  built libspng
}

r_libwebp() {
  local s; s=$(fetch libwebp)
  cmake_build "$s" "$B" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON -DWEBP_LINK_STATIC=OFF
  license libwebp "$s/COPYING" "$s/PATENTS"
  built libwebp
}

r_libdeflate() {
  local s; s=$(fetch libdeflate)
  cmake_build "$s" "$B" -DLIBDEFLATE_BUILD_SHARED_LIB=ON -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF
  license libdeflate "$s/COPYING"
  built libdeflate
}

r_libtiff() {
  local s; s=$(fetch libtiff)
  cmake_build "$s" "$B" -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-opengl=OFF \
    -Djpeg=ON -Dzlib=ON -Dlibdeflate=ON -Dwebp=ON -Dzstd=ON -Dlzma=ON -Djbig=OFF -Dlerc=OFF -Djpeg12=OFF
  license libtiff "$s/LICENSE.md"
  built libtiff
}

r_imath() {
  local s; s=$(fetch imath)
  cmake_build "$s" "$B" -DPYTHON=OFF -DIMATH_INSTALL=ON
  license imath "$s/LICENSE.md"
  built imath
}

# HTJ2K uses the OpenJPH copy vendored in the OpenEXR release (BSD-2-Clause).
# OpenEXRCore uses SSE4.1 intrinsics whenever _MSC_VER is set (MSVC allows
# that without /arch); clang-cl needs the feature enabled. Same baseline as
# upstream MSVC builds; Windows 11 itself requires SSE4.2. CFLAGS is added to
# the toolchain's hardened CMAKE_C_FLAGS_INIT, it does not replace it.
r_openexr() {
  local s; s=$(fetch openexr)
  [ "$ARCH" = x64 ] && export CFLAGS="-msse4.1" CXXFLAGS="-msse4.1"
  cmake_build "$s" "$B" -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF -DOPENEXR_BUILD_EXAMPLES=OFF \
    -DOPENEXR_INSTALL_DOCS=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=OFF \
    -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_ZSTD=OFF -DOPENEXR_TEST_LIBRARIES=OFF \
    -DOPENEXR_TEST_TOOLS=OFF -DOPENEXR_TEST_PYTHON=OFF
  license openexr "$s/LICENSE.md" "$s/external/OpenJPH/LICENSE"
  built openexr
}

r_cgif() {
  local s; s=$(fetch cgif)
  meson_build "$s" "$B" -Dexamples=false -Dtests=false
  license cgif "$s/LICENSE"
  built cgif
}

r_highway() {
  local s; s=$(fetch highway)
  cmake_build "$s" "$B" -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF -DHWY_ENABLE_INSTALL=ON
  license highway "$s/LICENSE"
  built highway
}

r_brotli() {
  local s; s=$(fetch brotli)
  cmake_build "$s" "$B" -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
  license brotli "$s/LICENSE"
  built brotli
}

r_libjxl() {
  local s; s=$(fetch libjxl)
  cmake_build "$s" "$B" -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=ON \
    -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
    -DJPEGXL_WARNINGS_AS_ERRORS=OFF -DJPEGXL_STATIC=OFF
  license libjxl "$s/LICENSE" "$s/PATENTS"
  built libjxl
}

# Decode-only AVIF through dav1d; sharpyuv from libwebp.
r_libavif() {
  local s; s=$(fetch libavif)
  cmake_build "$s" "$B" -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_AOM=OFF -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF \
    -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=SYSTEM -DAVIF_LIBXML2=OFF -DAVIF_BUILD_APPS=OFF \
    -DAVIF_BUILD_EXAMPLES=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_MAN_PAGES=OFF
  license libavif "$s/LICENSE"
  built libavif
}

r_libraw() {
  local s; s=$(fetch libraw)
  cmake_build "$HERE/cmake/libraw" "$B" -DLIBRAW_SRC="$(w "$s")"
  license libraw "$s/LICENSE.CDDL" "$s/COPYRIGHT"
  built libraw
}

r_libexif() {
  local s; s=$(fetch libexif)
  cmake_build "$HERE/cmake/libexif" "$B" -DLIBEXIF_SRC="$(w "$s")" -DLIBEXIF_VERSION="$(pin libexif version)"
  license libexif "$s/COPYING"
  built libexif
}

# pcre2 and libffi come from glib's own wraps (meson verifies their hashes);
# both permissive and built as DLLs.
r_glib() {
  local s; s=$(fetch glib)
  meson_build "$s" "$B" --wrap-mode=default -Dtests=false -Dinstalled_tests=false -Dnls=disabled \
    -Dintrospection=disabled -Ddocumentation=false -Dman-pages=disabled -Dsysprof=disabled -Dlibelf=disabled \
    -Dpcre2:test=false -Dpcre2:grep=false
  license glib "$s/COPYING" "$s/LICENSES/LGPL-2.1-or-later.txt"
  local d; for d in "$s"/subprojects/pcre2-* "$s"/subprojects/libffi-* "$s"/subprojects/proxy-libintl-*; do
    [ -d "$d" ] || continue
    case $d in
      *pcre2*) license pcre2 "$d/LICENCE.md" ;;
      *libffi*) license libffi "$d/LICENSE" ;;
      *proxy-libintl*) license proxy-libintl "$d/COPYING" ;;
    esac
  done
  built glib pcre2 libffi proxy-libintl
}

r_libvips() {
  local s fl args=(); s=$(fetch libvips)
  fl=$(shared_meson_flags "$s" "$ROOT/flags/vips.flags"; flags_of "$HERE/flags/vips.flags")
  mapfile -t args <<<"$fl"
  # libvips calls close()/read() without <io.h>, where the MSVC CRT declares them.
  MESON_EXTRA_CFLAGS="-FIio.h" meson_build "$s" "$B" "${args[@]}"
  license libvips "$s/LICENSE"
  built libvips
}

# -------------------------------------------------------------- network
# OS crypto only (docs/07 rule 12): libssh2 on WinCNG, curl on Schannel/SSPI.

r_libssh2() {
  local s; s=$(fetch libssh2)
  cmake_build "$s" "$B" -DCRYPTO_BACKEND=WinCNG -DENABLE_ECDSA_WINCNG=ON -DENABLE_ZLIB_COMPRESSION=ON \
    -DBUILD_STATIC_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
  license libssh2 "$s/COPYING"
  built libssh2
}

r_curl() {
  local s; s=$(fetch curl)
  cmake_build "$s" "$B" -DCURL_USE_SCHANNEL=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF -DCURL_USE_WOLFSSL=OFF \
    -DCURL_USE_GNUTLS=OFF -DCURL_USE_RUSTLS=OFF -DCURL_USE_LIBSSH2=ON -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF \
    -DCURL_USE_LIBPSL=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DUSE_WIN32_IDN=ON -DCURL_ZLIB=ON -DCURL_BROTLI=ON \
    -DCURL_ZSTD=ON -DENABLE_UNICODE=ON -DCURL_DISABLE_LDAP=ON -DBUILD_CURL_EXE=OFF -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DBUILD_EXAMPLES=OFF
  license curl "$s/COPYING"
  built curl
}

# No Kerberos/GSSAPI; SMB3 signing and encryption use libsmb2's own code.
r_libsmb2() {
  local s; s=$(fetch libsmb2)
  cmake_build "$s" "$B" -DENABLE_GSSAPI=OFF -DENABLE_LIBKRB5=OFF -DENABLE_EXAMPLES=OFF
  license libsmb2 "$s/COPYING" "$s/LICENCE-LGPL-2.1.txt"
  built libsmb2
}

r_libnfs() {
  local s; s=$(fetch libnfs)
  cmake_build "$s" "$B" -DENABLE_UTILS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_DOCUMENTATION=OFF
  license libnfs "$s/COPYING" "$s/LICENCE-LGPL-2.1.txt"
  built libnfs
}

# ---------------------------------------------------------------- misc

# Hashes through Windows CNG; RAR via libarchive's own reader (no unrar).
r_libarchive() {
  local s; s=$(fetch libarchive)
  cmake_build "$s" "$B" -DENABLE_CNG=ON -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF \
    -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=ON -DENABLE_LZ4=OFF -DENABLE_LZO=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_WIN32_XMLLITE=ON -DENABLE_PCREPOSIX=OFF \
    -DENABLE_PCRE2POSIX=OFF -DENABLE_ICONV=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF \
    -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_WERROR=OFF
  license libarchive "$s/COPYING"
  built libarchive
}

r_libebur128() {
  local s; s=$(fetch libebur128)
  cmake_build "$s" "$B" -DENABLE_INTERNAL_QUEUE_H=ON
  license libebur128 "$s/COPYING"
  built libebur128
}

# FFT and resampling from the FFmpeg built above (libavutil tx, swresample).
r_chromaprint() {
  local s; s=$(fetch chromaprint)
  cmake_build "$s" "$B" -DFFT_LIB=avtx -DAUDIO_PROCESSOR_LIB=swresample -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF
  license chromaprint "$s/LICENSE.md"
  built chromaprint
}

# CPU backends for every x86-64 level, picked at run time (ggml backend DLLs).
r_whisper_cpp() {
  local s cpu=(); s=$(fetch whisper.cpp)
  if [ "$ARCH" = x64 ]; then cpu=(-DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON); fi
  cmake_build "$s" "$B" -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF "${cpu[@]}" \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_CURL=OFF \
    -DWHISPER_SDL=OFF -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF
  license whisper.cpp "$s/LICENSE"
  built whisper.cpp
}

# VVC software decoder (BSD-3-Clause-Clear, optional in versions.json).
# Like OpenEXR, vvdec uses SSE4.1 intrinsics in generic code whenever _MSC_VER
# is set (SSE4.1 baseline); clang-cl needs that, and xsave for _xgetbv.
r_vvdec() {
  local s; s=$(fetch vvdec)
  [ "$ARCH" = x64 ] && export CFLAGS="-msse4.1 -mxsave" CXXFLAGS="-msse4.1 -mxsave"
  cmake_build "$s" "$B" -DVVDEC_ENABLE_LINK_TIME_OPT=OFF -DVVDEC_INSTALL_VVDECAPP=OFF -DVVDEC_ENABLE_WERROR=OFF
  license vvdec "$s/LICENSE.txt"
  built vvdec
}
