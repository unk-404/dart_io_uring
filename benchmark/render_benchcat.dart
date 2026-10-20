// Converts C/Dart benchmark results into benchcat canonical JSON and renders
// assets/benchmarks.svg.
//
//   BENCHCAT=/path/to/benchcat dart run benchmark/render_benchcat.dart
//
// Set BENCHCAT_FONT_FILE (or --font-file) when the default DejaVu path is not
// available. Without --skip-run this re-runs benchmark/compare.dart first.
// `--emit-only` writes the canonical JSON and exits; CI then renders it with the
// unk-404/benchcat GitHub Action.

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux) {
    stderr.writeln('benchcat rendering is Linux-only in this repository.');
    exitCode = 1;
    return;
  }

  final skipRun = arguments.contains('--skip-run');
  final emitOnly = arguments.contains('--emit-only');
  final out = _option(arguments, '--out') ?? 'assets/benchmarks.svg';

  late Map<String, dynamic> compare;
  if (skipRun) {
    final file = File('build/benchmark_compare.json');
    if (!file.existsSync()) {
      stderr.writeln(
        'build/benchmark_compare.json not found; run without --skip-run.',
      );
      exitCode = 2;
      return;
    }
    compare = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } else {
    stderr.writeln('==> running benchmark/compare.dart --json');
    final run = await Process.run(Platform.resolvedExecutable, [
      'run',
      'benchmark/compare.dart',
      '--json',
    ]);
    if (run.exitCode != 0) {
      stderr
        ..write(run.stdout)
        ..write(run.stderr);
      exitCode = run.exitCode;
      return;
    }
    compare = jsonDecode((run.stdout as String).trim()) as Map<String, dynamic>;
  }

  final normalized = compare['normalized'] as Map<String, dynamic>;
  double value(String group, String key) {
    final entry = normalized[group] as Map<String, dynamic>;
    return (entry[key] as num).toDouble();
  }

  final arch = compare['arch']?.toString() ?? 'unknown';
  final directory = Directory('build/benchcat')..createSync(recursive: true);
  Directory('assets').createSync(recursive: true);

  File('${directory.path}/c.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(
      _report(
        tool: 'io_uring C',
        arch: arch,
        nopQd1: value('nopQd1', 'c'),
        nopBatch64: value('nopBatch64', 'c'),
        readMib: value('fileRead4kQd1', 'cMiBPerSec'),
      ),
    ),
  );
  File('${directory.path}/dart-sync.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(
      _report(
        tool: 'io_uring Dart (sync)',
        arch: arch,
        nopQd1: value('nopQd1', 'dartSync'),
        nopBatch64: value('nopBatch64', 'dartSync'),
        readMib: value('fileRead4kQd1', 'dartSyncMiBPerSec'),
      ),
    ),
  );
  File('${directory.path}/dart-async.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(
      _report(
        tool: 'io_uring Dart (async)',
        arch: arch,
        nopQd1: value('nopQd1', 'dartAsync'),
        nopBatch64: value('nopBatch64', 'dartAsync'),
        readMib: value('fileRead4kQd1', 'dartAsyncMiBPerSec'),
      ),
    ),
  );
  File('${directory.path}/dart-async-spin.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(
      _report(
        tool: 'io_uring Dart (async, spin)',
        arch: arch,
        nopQd1: value('nopQd1', 'dartAsyncSpin'),
        nopBatch64: value('nopBatch64', 'dartAsyncSpin'),
        readMib: value('fileRead4kQd1', 'dartAsyncSpinMiBPerSec'),
      ),
    ),
  );

  stderr.writeln(
    '==> wrote ${directory.path}/{c,dart-sync,dart-async,dart-async-spin}.json',
  );
  if (emitOnly) {
    stdout.writeln(directory.path);
    return;
  }

  final benchcat =
      _option(arguments, '--benchcat') ?? Platform.environment['BENCHCAT'];
  if (benchcat == null || benchcat.isEmpty) {
    stderr.writeln('Set BENCHCAT=/path/to/benchcat or pass --benchcat.');
    exitCode = 2;
    return;
  }

  final fontFile =
      _option(arguments, '--font-file') ??
      Platform.environment['BENCHCAT_FONT_FILE'] ??
      _defaultFont();
  if (fontFile == null) {
    stderr.writeln(
      'No TTF font found. Pass --font-file or set BENCHCAT_FONT_FILE.',
    );
    exitCode = 2;
    return;
  }

  stderr.writeln('==> rendering $out');
  final render = await Process.run(benchcat, [
    'render',
    '--config',
    'benchmark/benchcat.toml',
    '--out',
    out,
    '--font-file',
    fontFile,
  ]);
  if (render.exitCode != 0) {
    stderr
      ..write(render.stdout)
      ..write(render.stderr);
    exitCode = render.exitCode;
    return;
  }
  stdout.write(render.stdout);
  stderr.write(render.stderr);
  stdout.writeln('wrote $out');
}

Map<String, dynamic> _report({
  required String tool,
  required String arch,
  required double nopQd1,
  required double nopBatch64,
  required double readMib,
}) {
  return {
    'schema': 'benchcat/report@1',
    'meta': {
      'tool': tool,
      'platform': {'os': 'Linux', 'arch': arch},
    },
    'benchmarks': [
      {
        'id': 'nop.qd1',
        'group': 'NOP',
        'label': 'NOP QD1',
        'note': 'submit 1 · wait 1',
        'unit': 'ops/s',
        'value': nopQd1,
        'direction': 'higher',
      },
      {
        'id': 'nop.batch64',
        'group': 'NOP',
        'label': 'NOP batch 64',
        'note': '64 SQEs per submit',
        'unit': 'ops/s',
        'value': nopBatch64,
        'direction': 'higher',
      },
      {
        'id': 'read.4k.qd1',
        'group': 'File I/O',
        'label': '4K read QD1',
        'note': '1 MiB file · rotating offset',
        'unit': 'MiB/s',
        'value': readMib,
        'direction': 'higher',
      },
    ],
  };
}

String? _option(List<String> arguments, String name) {
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == name) return arguments[i + 1];
  }
  return null;
}

String? _defaultFont() {
  const candidates = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf',
    'fonts/DejaVuSans.ttf',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
