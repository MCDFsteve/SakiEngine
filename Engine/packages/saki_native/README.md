# saki_native

SakiEngine's shared Rust service layer, exposed to Flutter through
`flutter_rust_bridge`.

It currently owns the native implementations for:

- external asset indexing and memory-mapped SakiPack random access;
- `.sakisav` validation, header indexing, reads and atomic writes;
- SKS source analysis, dependency ordering and source merging;
- compact SKS runtime label/control-flow indexes and flowchart extraction;
- LZ4-compressed dialogue-history state snapshots;
- image dimension/decoded-memory preflight metadata;
- `.sakiread` migration and append-only persistence.

Long-running calls use the asynchronous bridge API so filesystem and parser
work does not block Flutter's UI isolate. Small runtime lookups and history
snapshot transforms use synchronous native calls to avoid extra scheduling
overhead. SakiEngine retains Dart/Web fallback implementations when the native
library is unavailable.

The runtime index intentionally accelerates script labels, menu seeking and
flowchart generation; rendering, transitions, audio and the complete game-state
machine remain in Flutter.

## Regenerating bindings

Run `flutter_rust_bridge_codegen generate` from this directory after changing
the public Rust API in `rust/src/api`.
