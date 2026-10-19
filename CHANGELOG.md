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
- Native buffers, raw-fd helpers (`openat`/`close`/`eventfd`/`read`), and a
  small memory-barrier abstraction.
- x86_64 support; aarch64 ring publication uses libatomic fences with a
  pthread fallback and is exercised by CI.
- Benchmark harness (`benchmark/run.dart`) with NOP throughput, QD1 NOP latency,
  and QD1 file-read metrics; CI builds and runs it on both architectures.
