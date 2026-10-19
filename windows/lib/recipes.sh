# Per-library build recipes for windows/build.sh (sourced).
# Each r_<name> runs in a subshell with B (its build dir), T, PREFIX, ARCH set,
# installs into $PREFIX, records licences with `license` and what it produced
# with `built`. Order matters: dependencies first.
# shellcheck shell=bash

RECIPES="zlib bzip2 xz zstd expat
vulkan_headers vulkan_loader spirv_cross shaderc
lcms2 dav1d libogg opus flac libvpx libopenmpt ffmpeg
freetype fribidi harfbuzz fontconfig libass libplacebo uchardet win_iconv libjpeg_turbo libudfread libbluray mpv"

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
  cmake_build "$s" "$B" -DBUILD_TESTS=OFF -DBUILD_WERROR=OFF -DUPDATE_DEPS=OFF \
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
  local s; s=$(fetch opus)
  cmake_build "$s" "$B" -DOPUS_BUILD_SHARED_LIBRARY=ON -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
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
  "$s/configure" --target="$VPX_ARCH-win64-vs$vs" --as=nasm --disable-examples --disable-tools --disable-docs \
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
  [ "$ARCH" = arm64 ] && cross=(--enable-cross-compile)
  cc="clang-cl -target $CLANG_TARGET"
  # Host tools (table generators) link with MSVC link.exe like the libraries;
  # clang-cl from the LLVM release would otherwise drive lld-link.
  "$s/configure" "${args[@]}" "${cross[@]}" --arch="$FF_ARCH" --cc="$cc" --cxx="$cc" \
    --host-cc=clang-cl --host-ld="$s/compat/windows/mslink" \
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
