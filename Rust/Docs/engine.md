# Parchley engine bridge

`parchly-core` is the typed runtime. It pins `pdf-inspector` 1.17.0 and keeps
passwords out of snapshots and result files. `parchly-ffi` exports the narrow C
ABI in `include/parchly.h`; JSON is used only at that ABI boundary.

The first UniFFI generation spike was not adopted because exposing the core
types directly would require duplicating every serde record and would make the
Swift 6 generated async lifetime behavior part of the engine contract. The C
ABI keeps the bridge narrow and explicit. It uses opaque handles, explicit
free functions, and synchronous nonblocking controls.
Workers own all allocations until terminal state and Swift must keep the job
handle alive while polling.

Build artifacts are `Rust/target/release/libparchly_ffi.a` and
`Rust/target/release/libparchly_ffi.dylib` after `Scripts/build-rust.sh`.
