// Dart io_uring benchmarks, run through the benchmark_test CLI.
//
//   dart run benchmark_test --compile aot \
//     --output jsonl benchmark/dart_io_uring_benchmark_test.dart
//
// The comparison script (benchmark/compare.dart) parses the JSONL output and
// merges it with the native C benchmark.

import 'dart:io';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  group('io_uring_dart', () {
    late IoUring syncRing;
    late UringLoop loop;
    late Directory directory;
    late File file;
    late int fd;
    late UringBuffer buffer;
    late UringBuffer rawCqes;
    var readOffset = 0;

    setUpAll(() async {
      syncRing = IoUring(entries: 256);
      loop = await UringLoop.open(entries: 256);
      directory = Directory.systemTemp.createTempSync('io_uring_bench_dart_');
      file = File('${directory.path}/data.bin')
        ..writeAsBytesSync(List<int>.filled(1024 * 1024, 0x41));
      fd = Posix.open(file.path);
      buffer = UringBuffer.allocate(4096);
      rawCqes = UringBuffer.allocate(64 * 16);
    });

    tearDownAll(() async {
      await loop.close();
      syncRing.close();
      rawCqes.dispose();
      buffer.dispose();
      Posix.close(fd);
      directory.deleteSync(recursive: true);
    });

    benchmark(
      'nop_qd1_sync',
      () {
        syncRing.push(const NopOp());
        syncRing.submitAndWait(1);
        final cqe = syncRing.waitCqe();
        if (cqe.isError) {
          throw StateError('NOP failed: ${cqe.errno}');
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'nop_batch64_sync',
      () {
        for (var i = 0; i < 64; i++) {
          syncRing.push(const NopOp());
        }
        syncRing.submitAndWait(64);
        for (var i = 0; i < 64; i++) {
          final cqe = syncRing.waitCqe();
          if (cqe.isError) {
            throw StateError('NOP failed: ${cqe.errno}');
          }
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'nop_batch64_sync_raw',
      () {
        for (var i = 0; i < 64; i++) {
          syncRing.push(const NopOp());
        }
        syncRing.submitAndWait(64);
        final reaped = syncRing.reapCqes(rawCqes.pointer, 64);
        if (reaped != 64) {
          throw StateError('expected 64 raw CQEs, got $reaped');
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'nop_qd1_async',
      () async {
        final cqe = await loop.run(const NopOp());
        if (cqe.isError) {
          throw StateError('NOP failed: ${cqe.errno}');
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'nop_batch64_async',
      () async {
        final futures = loop.runAll(List<UringOp>.filled(64, const NopOp()));
        final completions = await Future.wait(futures);
        for (final cqe in completions) {
          if (cqe.isError) {
            throw StateError('NOP failed: ${cqe.errno}');
          }
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'read_4k_qd1_sync',
      () {
        readOffset = (readOffset + 4096) % (1024 * 1024);
        syncRing.push(
          ReadOp(
            fd: fd,
            buffer: buffer.pointer,
            length: 4096,
            offset: readOffset,
          ),
        );
        syncRing.submitAndWait(1);
        final cqe = syncRing.waitCqe();
        if (cqe.isError) {
          throw StateError('READ failed: ${cqe.errno}');
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );

    benchmark(
      'read_4k_qd1_async',
      () async {
        readOffset = (readOffset + 4096) % (1024 * 1024);
        final cqe = await loop.run(
          ReadOp(
            fd: fd,
            buffer: buffer.pointer,
            length: 4096,
            offset: readOffset,
          ),
        );
        if (cqe.isError) {
          throw StateError('READ failed: ${cqe.errno}');
        }
      },
      minDuration: const Duration(seconds: 1),
      warmupMinSamples: 2,
    );
  });
}
