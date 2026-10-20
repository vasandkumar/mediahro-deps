# LibRaw (taken under CDDL-1.0) as raw.dll, the same sources and defines as
# upstream's Makefile.msvc DLL build (lane B4c). zlib (deflate DNG), libjpeg
# (lossy DNG) and lcms2 (colour profiles) are enabled; no RawSpeed, no DNG SDK.
cmake_minimum_required(VERSION 3.20)
project(libraw LANGUAGES C CXX)
set(S "${LIBRAW_SRC}")

file(GLOB srcs ${S}/src/*.cpp ${S}/src/*/*.cpp)
# Included into other translation units, not compiled on their own.
list(FILTER srcs EXCLUDE REGEX "_ph\\.cpp$")

file(STRINGS "${S}/libraw/libraw_version.h" vh REGEX "#define LIBRAW_(MAJOR|MINOR|PATCH)_VERSION")
foreach(line IN LISTS vh)
  if(line MATCHES "LIBRAW_(MAJOR|MINOR|PATCH)_VERSION[ \t]+([0-9]+)")
    set(V_${CMAKE_MATCH_1} ${CMAKE_MATCH_2})
  endif()
endforeach()

find_package(ZLIB REQUIRED)
find_package(JPEG REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LCMS2 REQUIRED IMPORTED_TARGET lcms2)

add_library(raw SHARED ${srcs})
target_compile_definitions(raw PRIVATE LIBRAW_BUILDLIB WIN32 _CRT_SECURE_NO_WARNINGS USE_ZLIB USE_JPEG USE_LCMS2 CMS_DLL)
target_include_directories(raw PRIVATE ${S})
target_link_libraries(raw PRIVATE ZLIB::ZLIB JPEG::JPEG PkgConfig::LCMS2 ws2_32)

install(TARGETS raw RUNTIME DESTINATION bin ARCHIVE DESTINATION lib LIBRARY DESTINATION lib)
install(DIRECTORY ${S}/libraw/ DESTINATION include/libraw FILES_MATCHING PATTERN "*.h")
file(WRITE ${CMAKE_BINARY_DIR}/libraw.pc
"prefix=${CMAKE_INSTALL_PREFIX}\nlibdir=\${prefix}/lib\nincludedir=\${prefix}/include\n\nName: libraw\nDescription: Raw image decoder library (non-thread-safe)\nVersion: ${V_MAJOR}.${V_MINOR}.${V_PATCH}\nRequires.private: zlib libjpeg lcms2\nLibs: -L\${libdir} -lraw\nCflags: -I\${includedir}/libraw -I\${includedir}\n")
install(FILES ${CMAKE_BINARY_DIR}/libraw.pc DESTINATION lib/pkgconfig)
configure_file(${CMAKE_BINARY_DIR}/libraw.pc ${CMAKE_BINARY_DIR}/libraw_r.pc COPYONLY)
install(FILES ${CMAKE_BINARY_DIR}/libraw_r.pc DESTINATION lib/pkgconfig)
