// Benchmark harness for the io_uring package.
//
// Usage:
//   dart run benchmark/run.dart [nopOps]
//
// It prints a single JSON object on stdout so CI can archive it as an artifact.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:io_uring/io_uring.dart';

void main(List<String> arguments) {
  if (!Platform.isLinux) {
    stderr.writeln('io_uring benchmarks are Linux-only.');
    exitCode = 1;
    return;
  }

  final nopOps = arguments.isEmpty
      ? 100000
      : int.tryParse(arguments.first) ?? 100000;

  final result = <String, Object?>{
    'arch': Abi.current().toString(),
    'os': Platform.operatingSystemVersion,
    'nopOps': nopOps,
    'nopThroughput': _benchNopThroughput(nopOps),
    'nopQd1Latency': _benchNopLatency(2000),
    'fileReadQd1': _benchFileRead(256, 4096),
  };

  stdout.writeln(jsonEncode(result));
}

Map<String, Object?> _benchNopThroughput(int requestedOps) {
  const entries = 256;
  const batch = 256;
  final rounds = (requestedOps ~/ batch).clamp(1, 1 << 30);
  final ops = rounds * batch;

  final ring = IoUring(entries: entries);
  try {
    // Warmup.
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < batch; i++) {
        ring.push(const NopOp(), userData: i);
      }
      ring.submitAndWait(batch);
      _reap(ring, batch);
    }

    final stopwatch = Stopwatch()..start();
    for (var round = 0; round < rounds; round++) {
      for (var i = 0; i < batch; i++) {
        ring.push(const NopOp(), userData: i);
      }
      ring.submitAndWait(batch);
      _reap(ring, batch);
    }
    stopwatch.stop();

    final seconds = stopwatch.elapsedMicroseconds / 1e6;
    return {
      'totalOps': ops,
      'totalMs': stopwatch.elapsedMilliseconds,
      'opsPerSec': seconds == 0 ? 0 : (ops / seconds).round(),
      'usPerOp': (stopwatch.elapsedMicroseconds / ops).toStringAsFixed(3),
    };
  } finally {
    ring.close();
  }
}

Map<String, Object?> _benchNopLatency(int iterations) {
  final ring = IoUring(entries: 8);
  try {
    // Warmup.
    for (var i = 0; i < 100; i++) {
      ring.push(const NopOp(), userData: i);
      ring.submitAndWait(1);
      _reap(ring, 1);
    }

    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      ring.push(const NopOp(), userData: i);
      ring.submitAndWait(1);
      _reap(ring, 1);
    }
    stopwatch.stop();

    return {
      'iterations': iterations,
      'totalMs': stopwatch.elapsedMilliseconds,
      'usPerOp': (stopwatch.elapsedMicroseconds / iterations).toStringAsFixed(
        3,
      ),
    };
  } finally {
    ring.close();
  }
}

Map<String, Object?> _benchFileRead(int operations, int bufferSize) {
  final directory = Directory.systemTemp.createTempSync('io_uring_bench_');
  final file = File('${directory.path}/data.bin')
    ..writeAsBytesSync(List<int>.filled(1024 * 1024, 0x41));
  final ring = IoUring(entries: 8);
  final buffer = UringBuffer.allocate(bufferSize);
  final path = UringPath(file.path);
  var fd = -1;
  try {
    ring.push(OpenAtOp(path: path), userData: 0);
    ring.submitAndWait(1);
    final openCqe = _reap(ring, 1);
    if (openCqe.isError) {
      throw StateError('OPENAT failed with errno ${openCqe.errno}');
    }
    fd = openCqe.result;

    final fileSize = file.lengthSync();
    // Warmup.
    for (var i = 0; i < 8; i++) {
      ring.push(
        ReadOp(
          fd: fd,
          buffer: buffer.pointer,
          length: bufferSize,
          offset: (i * bufferSize) % fileSize,
        ),
        userData: i,
      );
      ring.submitAndWait(1);
      _reap(ring, 1);
    }

    final stopwatch = Stopwatch()..start();
    var bytes = 0;
    for (var i = 0; i < operations; i++) {
      ring.push(
        ReadOp(
          fd: fd,
          buffer: buffer.pointer,
          length: bufferSize,
          offset: (i * bufferSize) % fileSize,
        ),
        userData: i,
      );
      ring.submitAndWait(1);
      final cqe = _reap(ring, 1);
      if (cqe.isError) {
        throw StateError('READ failed with errno ${cqe.errno}');
      }
      bytes += cqe.result;
    }
    stopwatch.stop();

    final seconds = stopwatch.elapsedMicroseconds / 1e6;
    return {
      'operations': operations,
      'bufferSize': bufferSize,
      'bytes': bytes,
      'totalMs': stopwatch.elapsedMilliseconds,
      'usPerOp': (stopwatch.elapsedMicroseconds / operations).toStringAsFixed(
        3,
      ),
      'mibPerSec': seconds == 0
          ? 0
          : (bytes / (1024 * 1024) / seconds).toStringAsFixed(1),
    };
  } finally {
    ring.close();
    buffer.dispose();
    path.dispose();
    if (fd >= 0) {
      Posix.close(fd);
    }
    directory.deleteSync(recursive: true);
  }
}

IoUringCompletion _reap(IoUring ring, int count) {
  IoUringCompletion? last;
  for (var i = 0; i < count; i++) {
    last = ring.waitCqe();
  }
  return last!;
}
