## 0.1.1

- `UringLoopPool` / `UringLoopLease`: exclusive, reference-counted loop leases
  with idle-loop reuse, reaper lifecycle, close coordination, and reaper error
  propagation.
- `UringLoop.acquire(entries: ..., spin: ...)` convenience for short-lived
  callers using the shared pool.
- Optional low-latency busy-poll reaper (`spin: true`): trades a CPU core for
  much lower async QD1 wake-up latency.
- Async completion path uses synchronous completers and the direct `List<int>`
  message fast path.
- Benchmarks cover spin-mode async I/O and pool acquire/release; chart uses an
  honest linear scale.
- Dartdoc coverage raised above the pub.dev 20% threshold (previously 17.2%),
  restoring the documentation score for v0.1.1.

## 0.1.0

- Initial implementation: ring setup/teardown, SQ/CQ submission, NOP/READ/
  WRITE/FSYNC, OPENAT/CLOSE/STATX/READV/WRITEV/FTRUNCATE/FALLOCATE.
- Registered buffers, registered files, eventfd registration and kernel probe.
- Network operations: SOCKET/BIND/LISTEN/ACCEPT/CONNECT/SEND/RECV/SHUTDOWN,
  with a loopback TCP echo test and example.
- SPLICE/TEE with pipe helpers and tests.
- Links, relative/absolute timeouts, timeout removal, link timeouts, async
  cancellation, poll add/remove, provided buffers and multishot receive.
- `IoUringBuilder` with SQPOLL/IOPOLL/CQ-size/taskrun flags and SQPOLL wakeup.
- Registered-file updates (`registerFilesUpdate` / `FilesUpdateOp`) and
  provided-buffer rings (`registerBufRing` / `UringBufRing`).
- Future-based `UringLoop`: owner submits directly, a reaper isolate blocks in
  `io_uring_enter` and completes Futures.
- C vs Dart benchmark suite: raw-syscall C ring and `benchmark_test` AOT Dart
  suite, with a comparison runner (`benchmark/compare.dart`).
- `bench-svg` integration: canonical JSON + `benchmark/bench-svg.toml` render
  `assets/benchmarks.svg`, embedded in the README.
- CI benchmark job after tests: runs C/Dart benchmarks, emits canonical JSON,
  renders the SVG with `unk-404/benchmark_svg@master` (config-defined series, no
  positional input), uploads artifacts, and commits the refreshed chart back to
  the branch.
- Hot-path performance work: 8×64-bit SQE zeroing, cached SQE Struct views,
  x86_64 barrier-fence elision (TSO), removed redundant CQ-head stores, and
  `reapCqes` raw batch reaping without per-completion object allocation.
- Native buffers, raw-fd helpers (`openat`/`close`/`eventfd`/`read`), and a
  small memory-barrier abstraction.
- x86_64 support; aarch64 ring publication uses libatomic fences with a
  pthread fallback and is exercised by CI.
- Benchmark harness (`benchmark/run.dart`) with NOP throughput, QD1 NOP latency,
  and QD1 file-read metrics; CI builds and runs it on both architectures.
