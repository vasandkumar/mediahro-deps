# libexif (LGPL-2.1-or-later, so a DLL) from the upstream autotools tarball,
# built as exif.dll with the export list upstream ships in libexif.sym
# (lane B4c). No NLS: messages stay in English, as the app localises its own UI.
cmake_minimum_required(VERSION 3.20)
project(libexif LANGUAGES C)
set(S "${LIBEXIF_SRC}")

set(VERSION "${LIBEXIF_VERSION}")

file(GLOB srcs ${S}/libexif/*.c ${S}/libexif/canon/*.c ${S}/libexif/fuji/*.c
               ${S}/libexif/olympus/*.c ${S}/libexif/pentax/*.c ${S}/libexif/apple/*.c)

file(WRITE ${CMAKE_BINARY_DIR}/config.h
"#define GETTEXT_PACKAGE \"libexif-12\"\n#define LOCALEDIR \"\"\n#define HAVE_LOCALTIME_S 1\n#define HAVE_STDINT_H 1\n#define HAVE_INTTYPES_H 1\n#define HAVE_STDLIB_H 1\n#define HAVE_STRING_H 1\n#define PACKAGE \"libexif\"\n#define VERSION \"${VERSION}\"\n#define PACKAGE_VERSION \"${VERSION}\"\n#include <basetsd.h>\ntypedef SSIZE_T ssize_t;\n")
file(STRINGS ${S}/libexif/libexif.sym syms)
set(def "EXPORTS\n")
foreach(sym IN LISTS syms)
  if(sym)
    string(APPEND def "  ${sym}\n")
  endif()
endforeach()
file(WRITE ${CMAKE_BINARY_DIR}/exif.def "${def}")

add_library(exif SHARED ${srcs} ${CMAKE_BINARY_DIR}/exif.def)
target_compile_definitions(exif PRIVATE HAVE_CONFIG_H _CRT_SECURE_NO_WARNINGS)
target_include_directories(exif PRIVATE ${CMAKE_BINARY_DIR} ${S} ${S}/libexif)

install(TARGETS exif RUNTIME DESTINATION bin ARCHIVE DESTINATION lib LIBRARY DESTINATION lib)
file(GLOB hdrs ${S}/libexif/exif-*.h)
list(FILTER hdrs EXCLUDE REGEX "priv")
install(FILES ${hdrs} ${S}/libexif/exif.h ${S}/libexif/_stdint.h DESTINATION include/libexif)
file(WRITE ${CMAKE_BINARY_DIR}/libexif.pc
"prefix=${CMAKE_INSTALL_PREFIX}\nlibdir=\${prefix}/lib\nincludedir=\${prefix}/include\n\nName: libexif\nDescription: Library for easy access to EXIF data\nVersion: ${VERSION}\nLibs: -L\${libdir} -lexif\nCflags: -I\${includedir}\n")
install(FILES ${CMAKE_BINARY_DIR}/libexif.pc DESTINATION lib/pkgconfig)
