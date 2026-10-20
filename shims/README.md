# C shims for dart:ffi (ADR-034)

CLD3 and the Bergamot translator are C++ only. Mediahro's `packages/mediahro_ffi` (lane C1) binds a small C API, and
these sources implement it. They are compiled into the libraries mediahro-deps ships, which export only these
symbols:

| Library (Android) | Shim | Exports |
|---|---|---|
| `libcld3.so` | `cld3/mediahro_cld3.cc` (Apache-2.0, like CLD3) | `mh_cld3_new`, `mh_cld3_free`, `mh_cld3_find` |
| `libbergamot.so` | `bergamot/mediahro_bergamot.cc` (MPL-2.0, like bergamot-translator) | `mh_bergamot_new`, `_free`, `_load`, `_model_free`, `_translate`, `_free_text` |

The headers are the contract. They are copies of the app repository's
`packages/mediahro_ffi/lib/src/{cld3,bergamot}/include/*.h` (mediahro `c6ee70b`), and the `.cc` files come from
lane C1's hand-over note. If the app's headers change, copy them here in the same change as the shim. Each archive
ships the header under `include/`.

Everything else in those libraries is hidden: the shims are compiled with `-fvisibility=hidden`, and the static
dependencies are linked with `-Wl,--exclude-libs,ALL`.
