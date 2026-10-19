# io_uring

A pure-Dart interface to Linux `io_uring`: hand-written submission/completion
rings over raw syscalls via `dart:ffi`. No C sources, no native build step, no
`liburing`.

## Features

- `io_uring_setup` / `io_uring_enter` / `io_uring_register` through libc's
  `syscall()`; ring memory is mapped with `mmap`.
- Hand-written SQ/CQ rings, 64-byte SQEs, 16-byte CQEs, kernel-reported offsets.
- Batch submission, blocking wait, non-blocking completion polling.
- Typed operations: `NOP`, `READ`, `WRITE`, `FSYNC`, `OPENAT`, `CLOSE`,
  `STATX`, `READV`, `WRITEV`, `READ_FIXED`, `WRITE_FIXED`, `FTRUNCATE`,
  `FALLOCATE`, `SOCKET`, `BIND`, `LISTEN`, `ACCEPT`, `CONNECT`, `SEND`, `RECV`,
  `SHUTDOWN`, `SPLICE`, `TEE`.
- Registered buffers, registered files, and eventfd notification.
- Links (`IOSQE_IO_LINK`), relative/absolute timeouts, timeout removal, link
  timeouts, async cancellation, poll add/remove, provided buffers and multishot
  receive.
- `IoUringBuilder` with SQPOLL/IOPOLL/CQ-size/taskrun options; SQPOLL wakeup
  handling.
- Registered-file updates and provided-buffer rings (`UringBufRing`).
- Kernel probe (`IORING_REGISTER_PROBE`) for per-op support checks.
- Native buffer, `iovec`, IPv4 `sockaddr_in` and pipe helpers; raw fd helpers
  (`openat`, `close`, `eventfd`, `read`, `write`, `getsockname`, `pipe2`).

## Requirements

- Linux. `x86_64` and `aarch64` are both validated in CI; `aarch64` ring
  publication uses `libatomic` fences with a pthread fallback.
- Kernel 5.1+. `READ`/`WRITE` need 5.6+; the network set
  (`SOCKET`/`BIND`/`LISTEN`/`ACCEPT`/`CONNECT`/`SEND`/`RECV`/`SHUTDOWN`) needs
  5.19+.
- Dart 3.13+.

## Install

```yaml
dependencies:
  io_uring: ^0.1.0
```

## Usage

```dart
import 'dart:convert';
import 'dart:io';

import 'package:io_uring/io_uring.dart';

void main() {
  final ring = IoUring(entries: 8);
  final buffer = UringBuffer.allocate(256);
  final fd = Posix.open('/etc/hostname');

  try {
    ring.push(
      ReadOp(fd: fd, buffer: buffer.pointer, length: buffer.length),
      userData: 1,
    );
    ring.submitAndWait(1);

    final cqe = ring.waitCqe();
    if (cqe.isError) {
      throw IoUringException('read', cqe.errno);
    }
    stdout.write(utf8.decode(buffer.bytes.sublist(0, cqe.result)));
  } finally {
    ring.close();
    buffer.dispose();
    Posix.close(fd);
  }
}
```

Opening files through the ring:

```dart
final path = UringPath('/tmp/example.txt');
ring.push(OpenAtOp(path: path), userData: 1);
ring.submitAndWait(1);

final fd = ring.waitCqe().result; // >= 0 on success
// ... use fd ...
ring.push(CloseOp(fd: fd), userData: 2);
ring.submitAndWait(1);
path.dispose();
```

See `example/` for complete programs, including
[`tcp_echo.dart`](example/tcp_echo.dart) (a loopback TCP echo server). See
`test/` for probe, registration, vectored I/O, statx, fallocate, network, pipe,
timeout/cancel/poll, multishot and error-path coverage.

## Design notes

- The low-level API shape is inspired by the Rust [`io-uring`](https://github.com/tokio-rs/io-uring)
  crate (MIT OR Apache-2.0); this package is an independent Dart implementation.
- The kernel-reported `io_uring_params` offsets are used; no hard-coded offsets.
- SQEs are 64 bytes and CQEs are 16 bytes in this version; `SQE128`/`CQE32` and
  mixed rings are rejected explicitly.
- Buffers passed to the kernel must be native memory (`UringBuffer`); Dart heap
  typed data is not exposed to the kernel.
- x86_64 relies on TSO for ring publication; aarch64 uses `libatomic` fences
  with an uncontended-pthread fallback.
- `close()` must only be called after all in-flight operations have completed.

## Development

Run everything on Linux (WSL is fine):

```bash
dart pub get
dart analyze
dart test
dart run example/io_uring_example.dart
dart run example/tcp_echo.dart   # then: nc 127.0.0.1 <port>
dart compile exe example/io_uring_example.dart -o build/io_uring_example
```

Benchmarks:

```bash
dart run benchmark/run.dart 100000
# AOT:
dart compile exe benchmark/run.dart -o build/io_uring_benchmark
./build/io_uring_benchmark 100000
```

The benchmark emits one JSON object (NOP throughput, QD1 NOP latency, and QD1
file-read throughput).

CI runs `analyze` + `test` on `x86_64` and `aarch64`, builds the example and
benchmark with AOT, runs the benchmark, writes its JSON to the job summary, and
uploads the example binary plus benchmark results as artifacts. There is no
release/publish job.

## License

MIT. See [LICENSE](LICENSE).
