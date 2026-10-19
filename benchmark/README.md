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
reaper isolate reaps), a busy-poll spin reaper, and a raw batch-reap path using
`IoUring.reapCqes` (copies raw CQEs into a native buffer, no per-completion Dart
object). The C benchmark is synchronous only.

## Hot-path notes

The Dart implementation was optimized for the synchronous hot path:

- SQE zeroing uses eight 64-bit stores instead of a typed-list view + fillRange
- `IoUringSqe` Struct views are cached per SQE slot
- x86_64 omits memory-barrier FFI calls (TSO); aarch64 keeps real fences
- redundant CQ-head publication was removed
- `reapCqes` allows batch reaping without allocating one completion object per
  CQE
- `UringLoop.open(spin: true)` / `UringLoopPool(spin: true)` busy-polls the CQ
  for lower async wake-up latency; it burns a core while idle
- `UringLoopPool` reuses idle loops; the suite also measures acquire/release

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

## SVG chart

The README chart lives in `assets/benchmarks.svg`. It is rendered from both
suites by [`bench-svg`](https://github.com/unk-404/benchmark_svg) with
`benchmark/bench-svg.toml`:

```bash
BENCH_SVG=/path/to/bench-svg dart run benchmark/render_bench_svg.dart
# reuse build/benchmark_compare.json:
BENCH_SVG=/path/to/bench-svg dart run benchmark/render_bench_svg.dart --skip-run
# CI path: only emit canonical JSON, then let the GitHub Action render:
dart run benchmark/render_bench_svg.dart --emit-only
```

`render_bench_svg.dart` runs `compare.dart --json`, writes canonical
`bench-svg/report@1` inputs to `build/bench-svg/`, and (locally) invokes
`bench-svg render`. CI uses the standard
[`unk-404/benchmark_svg@master`](https://github.com/unk-404/benchmark_svg) action
with `benchmark/bench-svg.toml`; the config defines `[[series]]`, so the action's
optional `input` is omitted. The action installs its own binary from the action
repository, so CI does not download or run the CLI manually. Bars use the honest
linear scale (`bar_curve = "linear"`); async QD1 is intentionally shown at its
real size rather than compressed. Use `--font-file` or `BENCH_SVG_FONT_FILE` if
DejaVu Sans is not installed.

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
