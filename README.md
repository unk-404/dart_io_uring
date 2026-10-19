# io_uring

A pure-Dart interface to Linux `io_uring`: hand-written submission/completion
rings over raw syscalls via `dart:ffi`. The library has no C sources, no native
build step, and no `liburing`; `benchmark/c/` contains an optional native C
comparison benchmark.

## Features

- `io_uring_setup` / `io_uring_enter` / `io_uring_register` through libc's
  `syscall()`; ring memory is mapped with `mmap`.
- Hand-written SQ/CQ rings, 64-byte SQEs, 16-byte CQEs, kernel-reported offsets.
- Batch submission, blocking wait, non-blocking completion polling, and
  zero-allocation batch reaping (`reapCqes`).
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
- `UringLoop`: Future-based API with an owner/reaper isolate pair; the owner
  submits directly and a reaper isolate blocks in `io_uring_enter`.
- Kernel probe (`IORING_REGISTER_PROBE`) for per-op support checks.
- Native buffer, `iovec`, IPv4 `sockaddr_in` and pipe helpers; raw fd helpers
  (`openat`, `close`, `eventfd`, `read`, `write`, `getsockname`, `pipe2`).
- C vs Dart benchmark suite using raw-syscall C and
  [`benchmark_test`](https://pub.dev/packages/benchmark_test).

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

Future-based API:

```dart
final loop = await UringLoop.open(entries: 64);
try {
  final cqe = await loop.run(const NopOp());
  if (cqe.isError) {
    throw IoUringException('nop', cqe.errno);
  }
} finally {
  await loop.close();
}
```

The owner isolate submits directly; a reaper isolate blocks in
`io_uring_enter(GETEVENTS)` and returns CQEs. Do not call `waitCqe`/`nextCqe`
on `loop.ring`; use `loop.run` / `loop.runAll`.

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
- Hot-path optimizations: SQE zeroing uses eight 64-bit stores, SQE Struct
  views are cached per slot, x86_64 skips barrier FFI calls (TSO), redundant
  CQ-head stores are removed, and `reapCqes` copies raw CQEs without allocating
  one Dart object per completion.
- `close()` must only be called after all in-flight operations have completed.

## Development

Run everything on Linux (WSL is fine):

```bash
dart pub get
dart analyze
dart test
dart run example/io_uring_example.dart
dart run example/async_nop.dart
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

C vs Dart comparison (native C uses raw io_uring syscalls, no liburing; Dart
uses `benchmark_test` with AOT):

```bash
dart run benchmark/compare.dart
dart run benchmark/compare.dart --json   # pure JSON on stdout
```

It builds `benchmark/c/io_uring_bench.c`, runs it, runs
`benchmark/dart_io_uring_benchmark_test.dart`, prints a Markdown table, and
writes `build/benchmark_compare.json`. See `benchmark/README.md` for details.

![io_uring benchmark: native C vs Dart](https://raw.githubusercontent.com/unk-404/dart_io_uring/main/assets/benchmarks.svg)

The SVG is rendered from both benchmark suites by
[`bench-svg`](https://github.com/unk-404/benchmark_svg) using
`benchmark/bench-svg.toml`:

```bash
BENCH_SVG=/path/to/bench-svg dart run benchmark/render_bench_svg.dart
# reuse the last build/benchmark_compare.json:
BENCH_SVG=/path/to/bench-svg dart run benchmark/render_bench_svg.dart --skip-run
# only emit canonical JSON (used by CI):
dart run benchmark/render_bench_svg.dart --emit-only
```

`BENCH_SVG_FONT_FILE` (or `--font-file`) selects the TTF used for outlined
labels; the default is DejaVu Sans on Linux. These local commands are for
debugging only; CI uses the GitHub Action below.

CI runs `analyze` + `test` on `x86_64` and `aarch64`, builds and runs the AOT
example, and uploads the example binaries as artifacts. There is no
release/publish job.

The [CI benchmark job](https://github.com/unk-404/dart_io_uring/blob/main/.github/workflows/ci.yml)
depends on the test job, so it only runs after both architectures pass. It runs
the C and Dart benchmarks, emits canonical JSON, and renders
`assets/benchmarks.svg` with the standard
[`unk-404/benchmark_svg@master`](https://github.com/unk-404/benchmark_svg) GitHub
Action using `benchmark/bench-svg.toml`. The config defines `[[series]]`, so the
action's optional `input` is omitted. It uploads the SVG/JSON as artifacts and
commits the refreshed SVG back when it changed. The commit uses `[skip ci]` to
avoid a loop.

## License

MIT. See [LICENSE](LICENSE).
