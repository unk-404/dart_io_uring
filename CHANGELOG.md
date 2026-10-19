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
- Hot-path performance work: 8×64-bit SQE zeroing, cached SQE Struct views,
  x86_64 barrier-fence elision (TSO), removed redundant CQ-head stores, and
  `reapCqes` raw batch reaping without per-completion object allocation.
- Native buffers, raw-fd helpers (`openat`/`close`/`eventfd`/`read`), and a
  small memory-barrier abstraction.
- x86_64 support; aarch64 ring publication uses libatomic fences with a
  pthread fallback and is exercised by CI.
- Benchmark harness (`benchmark/run.dart`) with NOP throughput, QD1 NOP latency,
  and QD1 file-read metrics; CI builds and runs it on both architectures.
