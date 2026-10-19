# Shared helpers for windows/build.sh (sourced; bash under MSYS2).
# shellcheck shell=bash

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }
w() { cygpath -m "$1"; }  # C:/forward/slash path for native tools

# ---------------------------------------------------------------- host tools

ensure_msys_packages() {
  local need=()
  # MSYS2's own tools only: the inherited Windows PATH may hold Git's or
  # Strawberry Perl's builds, which use a different runtime.
  for t in make perl zstd patch diff; do [ -x "/usr/bin/$t.exe" ] || [ -x "/usr/bin/$t" ] || need+=("$t"); done
  [ ${#need[@]} -eq 0 ] && return 0
  command -v pacman >/dev/null || die "missing ${need[*]} and no pacman"
  log "pacman: installing make diffutils perl patch zstd"
  pacman -S --noconfirm --needed make diffutils perl patch zstd >&2
}

# Resolve the real CPython before PATH is rebuilt (skip the WindowsApps stub).
find_python() {
  local p
  for p in $(type -ap python python3 py 2>/dev/null); do
    case $p in *WindowsApps*) continue ;; esac
    if [ "$(basename "$p")" = py ] || [ "$(basename "$p")" = py.exe ]; then
      p=$("$p" -3 -c 'import sys; print(sys.executable)' | tr -d '\r'); p=$(cygpath -u "$p")
    fi
    "$p" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null && { echo "$p"; return; }
  done
  die "python >= 3.9 not found"
}

setup_tools() {
  local TOOLS=$WORK/tools
  mkdir -p "$TOOLS/bin" "$CACHE" "$SRC"
  HOST_PY=$(find_python)
  if [ ! -x "$WORK/venv/Scripts/python.exe" ]; then
    log "python venv ($HOST_PY)"
    "$HOST_PY" -m venv "$(w "$WORK/venv")"
  fi
  if ! cmp -s "$HERE/requirements.txt" "$WORK/venv/.requirements"; then
    "$WORK/venv/Scripts/python.exe" -m pip install -q --disable-pip-version-check --require-hashes \
      --only-binary=:all: -r "$(w "$HERE/requirements.txt")" >&2
    cp "$HERE/requirements.txt" "$WORK/venv/.requirements"
  fi
  PY=$WORK/venv/Scripts/python.exe

  LLVM=$(fetch llvm)
  NASM=$(fetch nasm)
  cp -f "$NASM/nasm.exe" "$TOOLS/bin/"
  [ -x "$LLVM/bin/clang-cl.exe" ] || die "clang-cl missing from $LLVM"

  VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -x "$VSWHERE" ] || die "vswhere not found"
  CMAKE_EXE=
}

# --------------------------------------------------------------- MSVC env

# Import vcvarsall for ARCH (x64|arm64) into this shell and rebuild PATH from
# scratch so no MinGW/MSYS compiler or GNU link.exe can be picked up.
load_msvc_env() {
  local arch=$1 req=Microsoft.VisualStudio.Component.VC.Tools.x86.x64 vcarg=x64
  if [ "$arch" = arm64 ]; then req="$req Microsoft.VisualStudio.Component.VC.Tools.ARM64"; vcarg=x64_arm64; fi
  # shellcheck disable=SC2086
  VS=$("$VSWHERE" -latest -products '*' $(printf -- '-requires %s ' $req) -property installationPath | tr -d '\r' | head -1)
  [ -n "$VS" ] || die "no Visual Studio with MSVC $arch tools (components: $req)"
  local bat=$T/vcvars.bat envf=$T/vcvars.txt
  # bash cannot carry "ProgramFiles(x86)" through MSYS2, and vcvarsall needs it.
  {
    printf '@set "ProgramFiles(x86)=%s"\r\n' "$(cygpath -w "$(dirname "$(dirname "$(dirname "$VSWHERE")")")")"
    printf '@set "PATH=%%PATH%%;%s"\r\n' "$(cygpath -w "$(dirname "$VSWHERE")")"
    printf '@call "%s\\VC\\Auxiliary\\Build\\vcvarsall.bat" %s >nul || exit /b 1\r\n@set\r\n' "$(cygpath -w "$VS")" "$vcarg"
  } > "$bat"
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "$(cygpath -w "$bat")" | tr -d '\r' > "$envf" || die "vcvarsall $vcarg failed"
  local k v vspath=
  while IFS='=' read -r k v; do
    case $k in
      Path|PATH) vspath=$v ;;
      INCLUDE|LIB|LIBPATH|VCINSTALLDIR|VCToolsInstallDir|VCToolsVersion|VCToolsRedistDir|VSINSTALLDIR|\
      WindowsSdkDir|WindowsSDKVersion|WindowsSdkBinPath|WindowsSdkVerBinPath|WindowsLibPath|UCRTVersion|\
      UniversalCRTSdkDir|ExtensionSdkDir|VSCMD_ARG_TGT_ARCH|VSCMD_ARG_HOST_ARCH|Platform|DevEnvDir|VisualStudioVersion)
        export "$k=$v" ;;
    esac
  done < "$envf"
  [ -n "$vspath" ] || die "vcvarsall gave no PATH"
  local p newpath="$WORK/venv/Scripts:$WORK/tools/bin:$LLVM/bin"
  local IFS=';'
  for p in $vspath; do
    case $p in *"Visual Studio"*|*"Windows Kits"*|*"Microsoft SDKs"*|*MSBuild*) newpath="$newpath:$(cygpath -u "$p")" ;; esac
  done
  unset IFS
  export PATH="$newpath:$(dirname "$HOST_PY"):/usr/bin:/c/Windows/System32:/c/Windows:/c/Windows/System32/WindowsPowerShell/v1.0"
  hash -r
  MSVC_BIN=$(dirname "$(command -v link.exe)")
  case $(command -v link.exe) in */usr/bin/*) die "GNU link shadows MSVC link" ;; esac
  command -v cmake >/dev/null || die "cmake not on PATH (pip cmake from requirements.txt)"
  log "MSVC $VCToolsVersion ($arch) from $VS; SDK $WindowsSDKVersion; $(clang-cl --version | head -1)"
}

# ------------------------------------------------------------ toolchains

# x64_libpaths: -LIBPATH flags for the x64 CRT and SDK libraries (build-machine
# tools in an arm64 cross build). 8.3 names, because make and meson pass link
# flags through sh unquoted and these live under "Program Files (x86)".
x64_libpaths() {
  local d p out=""
  for d in "${VCToolsInstallDir}lib\\x64" "${WindowsSdkDir}Lib\\${WindowsSDKVersion}ucrt\\x64" \
           "${WindowsSdkDir}Lib\\${WindowsSDKVersion}um\\x64"; do
    p=$(cygpath -m "$(cygpath -d "$d")")
    case $p in *[\ \(\)]*|"") echo "no 8.3 short name for $d (enable 8dot3 names on that volume)"; return 1 ;; esac
    out="$out -LIBPATH:$p"
  done
  echo "${out# }"
}

write_toolchains() {
  local arch=$1 cflags ldflags
  case $arch in
    x64) CLANG_TARGET=x86_64-pc-windows-msvc; MESON_CPU=x86_64; CMAKE_CPU=AMD64; FF_ARCH=x86_64; VPX_ARCH=x86_64; VS_PLATFORM=x64 ;;
    arm64) CLANG_TARGET=aarch64-pc-windows-msvc; MESON_CPU=aarch64; CMAKE_CPU=ARM64; FF_ARCH=aarch64; VPX_ARCH=arm64; VS_PLATFORM=ARM64 ;;
  esac
  # Hardening (docs/09 §2, lane brief): Control Flow Guard, ASLR with high
  # entropy, DEP, /GS stack cookies; CET shadow-stack compatibility on x64.
  HARDEN_CFLAGS="-guard:cf -GS -Gy -Gw -Zc:inline"
  HARDEN_LDFLAGS="-guard:cf -DYNAMICBASE -HIGHENTROPYVA -NXCOMPAT -OPT:REF -OPT:ICF -INCREMENTAL:NO"
  [ "$arch" = x64 ] && HARDEN_LDFLAGS="$HARDEN_LDFLAGS -CETCOMPAT"
  cflags="$HARDEN_CFLAGS -Wno-unused-command-line-argument -I$(w "$PREFIX/include")"
  ldflags="$HARDEN_LDFLAGS -LIBPATH:$(w "$PREFIX/lib")"
  CC_W="$(w "$LLVM/bin/clang-cl.exe")"
  # /clang:--target (not --target=): meson's rc.exe wrapper would hand a
  # "--" argument on to rc.exe.
  CC_TARGET_ARG="/clang:--target=$CLANG_TARGET"
  LINK_W="$(w "$MSVC_BIN/link.exe")"
  LIB_W="$(w "$MSVC_BIN/lib.exe")"
  RC_W="$(w "$(command -v rc.exe)")"
  MT_W="$(w "$(command -v mt.exe)")"
  PKGCONF_W="$(w "$WORK/tools/bin/pkgconf.exe")"

  local q; q() { local a out=""; for a in "$@"; do out="$out'$a', "; done; printf '[%s]' "${out%, }"; }
  # shellcheck disable=SC2086
  cat > "$T/meson.ini" <<EOF
[binaries]
c = ['$CC_W', '$CC_TARGET_ARG']
cpp = ['$CC_W', '$CC_TARGET_ARG']
c_ld = 'link'
cpp_ld = 'link'
ar = '$LIB_W'
windres = '$RC_W'
nasm = '$(w "$WORK/tools/bin/nasm.exe")'
pkg-config = '$PKGCONF_W'
pkgconfig = '$PKGCONF_W'
python = '$(w "$PY")'

[constants]
base_cflags = $(q $cflags)
base_ldflags = $(q $ldflags)

[built-in options]
c_args = base_cflags + ['-std:c17']
cpp_args = base_cflags + ['-EHsc']
c_link_args = base_ldflags
cpp_link_args = base_ldflags
b_vscrt = 'md'
b_ndebug = 'true'
buildtype = 'release'
default_library = 'shared'
wrap_mode = 'nodownload'

[properties]
pkg_config_libdir = ['$(w "$PREFIX/lib/pkgconfig")', '$(w "$PREFIX/share/pkgconfig")']
cmake_toolchain_file = '$(w "$T/toolchain.cmake")'
EOF
  if [ "$arch" = arm64 ]; then
    cat >> "$T/meson.ini" <<EOF
needs_exe_wrapper = true
# Answers for checks glib would otherwise have to run on the target.
growing_stack = false
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = false

[host_machine]
system = 'windows'
cpu_family = '$MESON_CPU'
cpu = '$MESON_CPU'
endian = 'little'
EOF
    MESON_MACHINE="--cross-file=$(w "$T/meson.ini")"
    # Build-machine (x64) compiler for generators some projects run while
    # building (fribidi's gen.tab, ...): x64 CRT/SDK libraries ahead of the
    # arm64 LIB from vcvars.
    local lp; lp=$(x64_libpaths) || die "$lp"
    cat > "$T/meson-build-machine.ini" <<EOF
[binaries]
c = ['$CC_W', '/clang:--target=x86_64-pc-windows-msvc']
cpp = ['$CC_W', '/clang:--target=x86_64-pc-windows-msvc']
c_ld = 'link'
cpp_ld = 'link'
ar = '$LIB_W'
pkg-config = '$PKGCONF_W'

[built-in options]
c_link_args = ['-MACHINE:X64', $(for p in $lp; do printf "'%s', " "$p"; done)'-NOLOGO']
cpp_link_args = ['-MACHINE:X64', $(for p in $lp; do printf "'%s', " "$p"; done)'-NOLOGO']
b_vscrt = 'md'
EOF
    MESON_BUILD_MACHINE="--native-file=$(w "$T/meson-build-machine.ini")"
  else
    MESON_MACHINE="--native-file=$(w "$T/meson.ini")"
    MESON_BUILD_MACHINE=
  fi

  {
    [ "$arch" = arm64 ] && printf 'set(CMAKE_SYSTEM_NAME Windows)\nset(CMAKE_SYSTEM_VERSION 10.0)\n'
    cat <<EOF
set(CMAKE_SYSTEM_PROCESSOR $CMAKE_CPU)
set(CMAKE_C_COMPILER "$CC_W")
set(CMAKE_CXX_COMPILER "$CC_W")
set(CMAKE_C_COMPILER_TARGET $CLANG_TARGET)
set(CMAKE_CXX_COMPILER_TARGET $CLANG_TARGET)
set(CMAKE_ASM_NASM_COMPILER "$(w "$WORK/tools/bin/nasm.exe")")
set(CMAKE_LINKER "$LINK_W")
set(CMAKE_AR "$LIB_W")
set(CMAKE_RC_COMPILER "$RC_W")
set(CMAKE_MT "$MT_W")
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
set(CMAKE_C_FLAGS_INIT "$cflags -std:c17")
set(CMAKE_CXX_FLAGS_INIT "$cflags -EHsc")
set(CMAKE_EXE_LINKER_FLAGS_INIT "$ldflags")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "$ldflags")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "$ldflags")
set(CMAKE_PREFIX_PATH "$(w "$PREFIX")")
set(CMAKE_FIND_ROOT_PATH "$(w "$PREFIX")")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(PKG_CONFIG_EXECUTABLE "$PKGCONF_W")
EOF
  } > "$T/toolchain.cmake"

  export PKG_CONFIG_LIBDIR="$(w "$PREFIX/lib/pkgconfig");$(w "$PREFIX/share/pkgconfig")"
  export PKG_CONFIG_PATH=
  export CMAKE_POLICY_VERSION_MINIMUM=3.5
  export CMAKE_GENERATOR=Ninja
  # cl.exe and link.exe read these as extra options; make would export its own
  # LINK variable into them if the name were in the environment at all.
  unset CL _CL_ LINK _LINK_
}

# ---------------------------------------------------------------- sources

# fetch NAME -> path of the verified, extracted (and patched) source tree
fetch() {
  local name=$1 dir
  dir=$("$HOST_PY" -I "$(w "$HERE/lib/pins.py")" fetch "$name" "$(w "$CACHE")" "$(w "$SRC")" | tr -d '\r') || die "fetch $name failed"
  dir=$(cygpath -u "$dir")
  if [ -d "$HERE/patches/$name" ] && [ ! -e "$dir/.mediahro-patched" ]; then
    local p
    for p in "$HERE/patches/$name"/*.patch; do
      log "patch $name: $(basename "$p")"
      patch -d "$dir" -p1 --forward --batch < "$p" >&2 || die "patch $p failed"
    done
    touch "$dir/.mediahro-patched"
  fi
  echo "$dir"
}

pin() { "$HOST_PY" -I "$(w "$HERE/lib/pins.py")" get "$1" "$2" | tr -d '\r'; }

# --------------------------------------------------------------- builders

cmake_build() {  # SRC BUILD [cmake args...]
  local s=$1 b=$2; shift 2
  rm -rf "$b"
  cmake -S "$(w "$s")" -B "$(w "$b")" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$(w "$T/toolchain.cmake")" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$(w "$PREFIX")" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_BINDIR=bin -DCMAKE_INSTALL_INCLUDEDIR=include \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW "$@"
  cmake --build "$(w "$b")" --parallel "$JOBS"
  cmake --install "$(w "$b")"
}

# MESON_EXTRA_LDFLAGS (space-separated) are appended to the hardened link
# flags through a second machine file; -Dc_link_args would replace them.
meson_build() {  # SRC BUILD [meson args...]
  local s=$1 b=$2 machine=("$MESON_MACHINE") f extra=""; shift 2
  [ -n "${MESON_BUILD_MACHINE:-}" ] && machine+=("$MESON_BUILD_MACHINE")
  rm -rf "$b"
  if [ -n "${MESON_EXTRA_LDFLAGS:-}${MESON_EXTRA_CFLAGS:-}" ]; then
    local cextra=""
    for f in ${MESON_EXTRA_LDFLAGS:-}; do extra="$extra, '$f'"; done
    for f in ${MESON_EXTRA_CFLAGS:-}; do cextra="$cextra, '$f'"; done
    mkdir -p "$(dirname "$b")"
    {
      echo "[built-in options]"
      printf "c_link_args = base_ldflags + [%s]\ncpp_link_args = base_ldflags + [%s]\n" "${extra#, }" "${extra#, }"
      printf "c_args = base_cflags + ['-std:c17', %s]\n" "${cextra#, }"
    } > "$b.extra.ini"
    [ -n "$cextra" ] || sed -i '/^c_args/d' "$b.extra.ini"
    machine+=("${MESON_MACHINE%%=*}=$(w "$b.extra.ini")")
  fi
  meson setup "$(w "$b")" "$(w "$s")" "${machine[@]}" \
    --prefix="$(w "$PREFIX")" --libdir=lib --bindir=bin --includedir=include "$@"
  meson compile -C "$(w "$b")" -j "$JOBS"
  meson install -C "$(w "$b")" --no-rebuild
}

# shared_meson_flags SRC FLAGS_FILE: the shared (B4a-owned) flags minus -D
# options this pinned source does not define (e.g. mpv 0.41 has no
# "libplacebo" option: it is always required). Dropped flags are logged.
shared_meson_flags() {
  local s=$1 f name opts
  opts=$(for f in "$s/meson.options" "$s/meson_options.txt"; do [ -f "$f" ] && cat "$f"; done |
         grep -oE "option\('[A-Za-z0-9_-]+'" | sed "s/option('//; s/'//" || true)
  [ -n "$opts" ] || die "shared_meson_flags: no meson options found in $s"
  while IFS= read -r f; do
    name=${f#-D}; name=${name%%=*}
    case $name in
      default_library|buildtype|b_*|c_std|cpp_std|warning_level|werror|wrap_mode) echo "$f"; continue ;;
    esac
    if [[ $f == -D* ]] && ! grep -qx -- "$name" <<<"$opts"; then
      echo "flags: dropping $f from $(basename "$2") (no such option in $(basename "$s"))" >&2; continue
    fi
    echo "$f"
  done < <(flags_of "$2")
}

flags_of() {  # FLAGS_FILE -> one flag per line, comments dropped
  grep -v '^[[:space:]]*#' "$1" | sed '/^[[:space:]]*$/d' | tr -d '\r'
}

# license NAME FILE... -> licenses/NAME.txt in the archive
license() {
  local name=$1 f; shift
  mkdir -p "$T/licenses"
  : > "$T/licenses/$name.txt"
  for f in "$@"; do
    [ -f "$f" ] || die "licence file $f missing for $name"
    { printf '==> %s <==\n' "$(basename "$f")"; cat "$f"; printf '\n'; } >> "$T/licenses/$name.txt"
  done
}

# Host pkgconf (x64, static) used by meson and CMake for every target.
build_host_pkgconf() {
  local v src b=$T/pkgconf
  v=$(pin pkgconf version)
  [ "$(cat "$WORK/tools/pkgconf.version" 2>/dev/null)" = "$v" ] && return 0
  src=$(fetch pkgconf)
  log "host pkgconf $v"
  rm -rf "$b"
  CC=cl meson setup "$(w "$b")" "$(w "$src")" --buildtype=release -Ddefault_library=static -Dtests=disabled >"$T/pkgconf.log" 2>&1 &&
    meson compile -C "$(w "$b")" >>"$T/pkgconf.log" 2>&1 || { tail -50 "$T/pkgconf.log" >&2; die "host pkgconf failed"; }
  cp -f "$b/pkgconf.exe" "$WORK/tools/bin/pkgconf.exe"
  echo "$v" > "$WORK/tools/pkgconf.version"
}
