# Architecture decision: native bridge

Parchley uses a small JSON C ABI for the app bridge while the Rust engine remains strongly typed internally. The ABI exposes engine creation, job admission, snapshots, cancellation, result descriptors, runtime configuration, and owned string release.

The release deliberately keeps this C ABI. A synchronous UniFFI UDL prototype was attempted against UniFFI 0.29.5, but its generated object scaffolding conflicts with the implementation types when the existing staticlib target is compiled (duplicate generated symbols and type inference errors). No generated UniFFI bindings or XCFramework are shipped from that failed gate. Swift polls snapshots and receives owned JSON strings, so the ownership and terminal state contract stays explicit at the boundary. A later UniFFI migration must preserve that contract while its generated bindings, static XCFramework packaging, and Swift 6 concurrency behavior are validated separately.
