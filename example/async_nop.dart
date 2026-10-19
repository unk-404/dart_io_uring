import 'dart:io';

import 'package:io_uring/io_uring.dart';

/// Minimal Future-based usage: one NOP through the reaper isolate.
Future<void> main() async {
  if (!Platform.isLinux) {
    stderr.writeln('io_uring is Linux-only; run this example in WSL or Linux.');
    exitCode = 1;
    return;
  }

  final loop = await UringLoop.open(entries: 16);
  try {
    final cqe = await loop.run(const NopOp());
    stdout.writeln('NOP result: ${cqe.result}');
  } finally {
    await loop.close();
  }
}
