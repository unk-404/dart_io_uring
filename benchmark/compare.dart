// Builds and runs the native C and Dart io_uring benchmarks, then prints a
// comparison table and writes build/benchmark_compare.json.
//
//   dart run benchmark/compare.dart
//   dart run benchmark/compare.dart --json

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux) {
    stderr.writeln('io_uring benchmarks are Linux-only.');
    exitCode = 1;
    return;
  }

  final jsonMode = arguments.contains('--json');
  final buildDirectory = Directory('build')..createSync(recursive: true);
  final cc = Platform.environment['CC'] ?? 'cc';
  final cBinary = '${buildDirectory.path}/io_uring_bench_c';
  const cSource = 'benchmark/c/io_uring_bench.c';

  stderr.writeln('==> compiling $cSource with $cc');
  final compile = await Process.run(cc, [
    '-O2',
    '-std=c11',
    '-Wall',
    '-Wextra',
    '-o',
    cBinary,
    cSource,
  ]);
  if (compile.exitCode != 0) {
    stderr
      ..write(compile.stdout)
      ..write(compile.stderr);
    exitCode = compile.exitCode;
    return;
  }

  stderr.writeln('==> running native C benchmark');
  final cRun = await Process.run('./$cBinary', const []);
  if (cRun.exitCode != 0) {
    stderr
      ..write(cRun.stdout)
      ..write(cRun.stderr);
    exitCode = cRun.exitCode;
    return;
  }
  final cResult =
      jsonDecode((cRun.stdout as String).trim()) as Map<String, dynamic>;

  stderr.writeln('==> running Dart benchmark_test (AOT)');
  final dartRun = await Process.run(Platform.resolvedExecutable, [
    'run',
    'benchmark_test',
    '--compile',
    'aot',
    '--output',
    'jsonl',
    'benchmark/dart_io_uring_benchmark_test.dart',
  ]);
  if (dartRun.exitCode != 0) {
    stderr
      ..write(dartRun.stdout)
      ..write(dartRun.stderr);
    exitCode = dartRun.exitCode;
    return;
  }

  final dartResults = <String, Map<String, dynamic>>{};
  for (final line in (dartRun.stdout as String).split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final name = decoded['name'];
        if (name is String) {
          dartResults[name] = decoded;
        }
      }
    } on FormatException {
      // Ignore non-JSON progress lines.
    }
  }

  Map<String, dynamic>? findBySuffix(String suffix) {
    for (final entry in dartResults.entries) {
      if (entry.key.endsWith(suffix)) return entry.value;
    }
    return null;
  }

  double dartOps(String suffix, {double multiplier = 1}) {
    final result = findBySuffix(suffix);
    if (result == null) return double.nan;
    final throughput = result['throughput'];
    if (throughput is! Map) return double.nan;
    final value = throughput['value'];
    return value is num ? value.toDouble() * multiplier : double.nan;
  }

  double dartLatencyUs(String suffix) {
    final result = findBySuffix(suffix);
    if (result == null) return double.nan;
    final latency = result['latency'];
    if (latency is! Map) return double.nan;
    final value = latency['mean'];
    return value is num ? value.toDouble() : double.nan;
  }

  double cOps(String scenario, String field) {
    final result = cResult[scenario];
    if (result is! Map) return double.nan;
    final value = result[field];
    return value is num ? value.toDouble() : double.nan;
  }

  const mib = 1024 * 1024;
  final rows = <List<String>>[
    [
      'NOP QD1 (Mops/s)',
      (cOps('nopQd1', 'opsPerSec') / 1e6).toStringAsFixed(2),
      (dartOps('nop_qd1_sync') / 1e6).toStringAsFixed(2),
      'n/a',
      (dartOps('nop_qd1_async') / 1e6).toStringAsFixed(2),
      (dartOps('nop_qd1_async_spin') / 1e6).toStringAsFixed(2),
    ],
    [
      'NOP batch64 (Mops/s)',
      (cOps('nopBatch64', 'opsPerSec') / 1e6).toStringAsFixed(2),
      (dartOps('nop_batch64_sync', multiplier: 64) / 1e6).toStringAsFixed(2),
      (dartOps('nop_batch64_sync_raw', multiplier: 64) / 1e6).toStringAsFixed(
        2,
      ),
      (dartOps('nop_batch64_async', multiplier: 64) / 1e6).toStringAsFixed(2),
      (dartOps('nop_batch64_async_spin', multiplier: 64) / 1e6).toStringAsFixed(
        2,
      ),
    ],
    [
      '4K read QD1 (MiB/s)',
      cOps('fileRead4kQd1', 'mibPerSec').toStringAsFixed(2),
      (dartOps('read_4k_qd1_sync') * 4096 / mib).toStringAsFixed(2),
      'n/a',
      (dartOps('read_4k_qd1_async') * 4096 / mib).toStringAsFixed(2),
      (dartOps('read_4k_qd1_async_spin') * 4096 / mib).toStringAsFixed(2),
    ],
  ];

  final normalized = {
    'nopQd1': {
      'c': cOps('nopQd1', 'opsPerSec'),
      'dartSync': dartOps('nop_qd1_sync'),
      'dartAsync': dartOps('nop_qd1_async'),
      'dartAsyncSpin': dartOps('nop_qd1_async_spin'),
    },
    'nopBatch64': {
      'c': cOps('nopBatch64', 'opsPerSec'),
      'dartSync': dartOps('nop_batch64_sync', multiplier: 64),
      'dartSyncRaw': dartOps('nop_batch64_sync_raw', multiplier: 64),
      'dartAsync': dartOps('nop_batch64_async', multiplier: 64),
      'dartAsyncSpin': dartOps('nop_batch64_async_spin', multiplier: 64),
    },
    'fileRead4kQd1': {
      'cMiBPerSec': cOps('fileRead4kQd1', 'mibPerSec'),
      'dartSyncMiBPerSec': dartOps('read_4k_qd1_sync') * 4096 / mib,
      'dartAsyncMiBPerSec': dartOps('read_4k_qd1_async') * 4096 / mib,
      'dartAsyncSpinMiBPerSec': dartOps('read_4k_qd1_async_spin') * 4096 / mib,
    },
    'loopPoolAcquireRelease': {
      'opsPerSec': dartOps('loop_pool_acquire_release'),
      'latencyUs': dartLatencyUs('loop_pool_acquire_release'),
    },
  };

  final output = <String, dynamic>{
    'arch': cResult['arch'],
    'c': cResult,
    'dart': dartResults,
    'normalized': normalized,
  };
  File('${buildDirectory.path}/benchmark_compare.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));

  if (jsonMode) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    return;
  }

  stdout
    ..writeln()
    ..writeln(
      '| Scenario | C | Dart sync | Dart sync raw | Dart async | Dart async spin |',
    )
    ..writeln('|---|---:|---:|---:|---:|---:|');
  for (final row in rows) {
    stdout.writeln(
      '| ${row[0]} | ${row[1]} | ${row[2]} | ${row[3]} | ${row[4]} | ${row[5]} |',
    );
  }
  final poolLatency = dartLatencyUs('loop_pool_acquire_release');
  stdout
    ..writeln()
    ..writeln('C: raw io_uring syscalls, no liburing.')
    ..writeln('Dart: benchmark_test, AOT, io_uring package.')
    ..writeln(
      'Dart sync raw: batch64 reaped with reapCqes (no per-CQE object).',
    )
    ..writeln(
      'Dart async spin: busy-poll reaper (lower latency, burns a core).',
    )
    ..writeln(
      poolLatency.isNaN
          ? 'Dart pool acquire/release: n/a'
          : 'Dart pool acquire/release: ${poolLatency.toStringAsFixed(3)} us/op',
    )
    ..writeln('Results: build/benchmark_compare.json');
}
