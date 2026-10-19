# libopenmpt from the upstream autotools tarball, built as openmpt.dll with
# MSVC-compatible tools (lane B4c). The source list is read from upstream's
# Makefile.am so it tracks the release exactly. zlib and libogg are used;
# MP3 / Vorbis samples inside MO3 files need mpg123 / libvorbis, which are not
# in versions.json (see windows/README.md).
cmake_minimum_required(VERSION 3.20)
project(libopenmpt LANGUAGES C CXX)
set(S "${OPENMPT_SRC}")

file(STRINGS "${S}/Makefile.am" am)
set(srcs)
foreach(line IN LISTS am)
  if(line MATCHES "^MPT_FILES_(SRC_OPENMPT|COMMON|SOUNDBASE|SOUNDLIB|SOUNDDSP) \\+= (.+\\.cpp)$")
    list(APPEND srcs "${S}/${CMAKE_MATCH_2}")
  endif()
endforeach()
list(LENGTH srcs n)
if(n LESS 100)
  message(FATAL_ERROR "libopenmpt: only ${n} sources found in Makefile.am")
endif()
list(APPEND srcs ${S}/libopenmpt/libopenmpt_c.cpp ${S}/libopenmpt/libopenmpt_cxx.cpp
                 ${S}/libopenmpt/libopenmpt_ext_impl.cpp ${S}/libopenmpt/libopenmpt_impl.cpp)

file(STRINGS "${S}/libopenmpt/libopenmpt_version.mk" vmk)
foreach(line IN LISTS vmk)
  if(line MATCHES "^LIBOPENMPT_VERSION_(MAJOR|MINOR|PATCH)=([0-9]+)")
    set(V_${CMAKE_MATCH_1} ${CMAKE_MATCH_2})
  endif()
endforeach()
set(VERSION "${V_MAJOR}.${V_MINOR}.${V_PATCH}")

find_package(ZLIB REQUIRED)
find_package(Ogg CONFIG REQUIRED)

add_library(openmpt SHARED ${srcs})
set_target_properties(openmpt PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON)
target_compile_definitions(openmpt PRIVATE LIBOPENMPT_BUILD LIBOPENMPT_BUILD_DLL
  MPT_WITH_ZLIB MPT_WITH_OGG _UNICODE UNICODE NOMINMAX _CRT_SECURE_NO_WARNINGS _CRT_SECURE_NO_DEPRECATE)
target_include_directories(openmpt PRIVATE ${S} ${S}/src ${S}/common ${S}/build/svn_version)
target_link_libraries(openmpt PRIVATE ZLIB::ZLIB Ogg::ogg ole32 rpcrt4)
if(MSVC)
  target_compile_options(openmpt PRIVATE /bigobj /utf-8)
endif()

install(TARGETS openmpt RUNTIME DESTINATION bin ARCHIVE DESTINATION lib LIBRARY DESTINATION lib)
install(FILES ${S}/libopenmpt/libopenmpt.h ${S}/libopenmpt/libopenmpt.hpp ${S}/libopenmpt/libopenmpt_config.h
              ${S}/libopenmpt/libopenmpt_ext.h ${S}/libopenmpt/libopenmpt_ext.hpp ${S}/libopenmpt/libopenmpt_version.h
              ${S}/libopenmpt/libopenmpt_stream_callbacks_buffer.h ${S}/libopenmpt/libopenmpt_stream_callbacks_fd.h
              ${S}/libopenmpt/libopenmpt_stream_callbacks_file.h ${S}/libopenmpt/libopenmpt_stream_callbacks_file_msvcrt.h
              ${S}/libopenmpt/libopenmpt_stream_callbacks_file_mingw.h ${S}/libopenmpt/libopenmpt_stream_callbacks_file_posix.h
              ${S}/libopenmpt/libopenmpt_stream_callbacks_file_posix_lfs64.h
        DESTINATION include/libopenmpt)
file(WRITE ${CMAKE_BINARY_DIR}/libopenmpt.pc
"prefix=${CMAKE_INSTALL_PREFIX}\nlibdir=\${prefix}/lib\nincludedir=\${prefix}/include\n\nName: libopenmpt\nDescription: Tracker module player based on OpenMPT\nVersion: ${VERSION}\nRequires.private: zlib ogg\nLibs: -L\${libdir} -lopenmpt\nCflags: -I\${includedir} -DLIBOPENMPT_USE_DLL\n")
install(FILES ${CMAKE_BINARY_DIR}/libopenmpt.pc DESTINATION lib/pkgconfig)
