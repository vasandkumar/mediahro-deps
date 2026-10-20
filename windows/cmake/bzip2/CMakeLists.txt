# bzip2 1.0.8 ships only makefile.msc (static). Build bz2.dll from the same
# sources with the upstream libbz2.def export list (lane B4c).
cmake_minimum_required(VERSION 3.20)
project(bzip2 VERSION 1.0.8 LANGUAGES C)
set(S "${BZIP2_SRC}")
# Drop the def file's LIBRARY line so the import library names bz2.dll, and
# its DESCRIPTION line, which lld-link does not accept.
file(READ ${S}/libbz2.def DEF)
string(REGEX REPLACE "(LIBRARY|DESCRIPTION)[^\n]*\n" "" DEF "${DEF}")
file(WRITE ${CMAKE_BINARY_DIR}/bz2.def "${DEF}")
add_library(bz2 SHARED
  ${S}/blocksort.c ${S}/huffman.c ${S}/crctable.c ${S}/randtable.c
  ${S}/compress.c ${S}/decompress.c ${S}/bzlib.c ${CMAKE_BINARY_DIR}/bz2.def)
target_compile_definitions(bz2 PRIVATE _CRT_SECURE_NO_WARNINGS)
target_include_directories(bz2 PUBLIC $<BUILD_INTERFACE:${S}> $<INSTALL_INTERFACE:include>)
install(TARGETS bz2 RUNTIME DESTINATION bin ARCHIVE DESTINATION lib LIBRARY DESTINATION lib)
install(FILES ${S}/bzlib.h DESTINATION include)
file(WRITE ${CMAKE_BINARY_DIR}/bzip2.pc
"prefix=${CMAKE_INSTALL_PREFIX}\nlibdir=\${prefix}/lib\nincludedir=\${prefix}/include\n\nName: bzip2\nDescription: bzip2 compression library\nVersion: ${PROJECT_VERSION}\nLibs: -L\${libdir} -lbz2\nCflags: -I\${includedir}\n")
install(FILES ${CMAKE_BINARY_DIR}/bzip2.pc DESTINATION lib/pkgconfig)
