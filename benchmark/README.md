# io_uring benchmarks: C vs Dart

Two implementations of the same scenarios:

- `c/io_uring_bench.c`: native C, raw `io_uring_setup` / `io_uring_enter`
  syscalls, hand-written SQ/CQ rings. No liburing.
- `dart_io_uring_benchmark_test.dart`: the Dart package, run through
  [`benchmark_test`](https://pub.dev/packages/benchmark_test).

## Scenarios

| Scenario | Workload |
|---|---|
| NOP QD1 | submit 1 NOP, wait for 1 CQE |
| NOP batch64 | submit 64 NOPs, wait for 64 CQEs |
| 4K read QD1 | `IORING_OP_READ` 4096 bytes from a 1 MiB file |

The comparison table reports `Dart sync raw` for batch64, which uses
`reapCqes` instead of `waitCqe` per completion.

The Dart suite additionally measures the async `UringLoop` path (owner submits,
reaper isolate reaps) and a raw batch-reap path using `IoUring.reapCqes` (copies
raw CQEs into a native buffer, no per-completion Dart object). The C benchmark is
synchronous only.

## Hot-path notes

The Dart implementation was optimized for the synchronous hot path:

- SQE zeroing uses eight 64-bit stores instead of a typed-list view + fillRange
- `IoUringSqe` Struct views are cached per SQE slot
- x86_64 omits memory-barrier FFI calls (TSO); aarch64 keeps real fences
- redundant CQ-head publication was removed
- `reapCqes` allows batch reaping without allocating one completion object per
  CQE

## Run

```bash
dart pub get
dart run benchmark/compare.dart
```

The comparison script:

1. compiles the C benchmark with `cc -O2`
2. runs it
3. runs `dart run benchmark_test --compile aot --output jsonl ...`
4. prints a Markdown table and writes `build/benchmark_compare.json`

Individual runs:

```bash
cc -O2 -std=c11 -Wall -Wextra -o build/io_uring_bench_c benchmark/c/io_uring_bench.c
./build/io_uring_bench_c

dart run benchmark_test --compile aot --output jsonl \
  benchmark/dart_io_uring_benchmark_test.dart
```

## Notes

- Numbers are machine-dependent and noisy on shared CI runners; compare trends,
  not absolute values.
- C uses raw syscalls; Dart uses the package's FFI/syscall path, so the gap
  includes FFI marshalling and Dart-level bookkeeping.
- `benchmark_test` reports throughput per benchmark body. For `batch64` bodies
  the comparison script normalizes to per-operation throughput by multiplying by
  64.
- A GitHub Benchmark Action can call `dart run benchmark/compare.dart --json`
  and upload `build/benchmark_compare.json` as an artifact.
