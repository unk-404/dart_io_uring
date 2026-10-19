import 'dart:convert';
import 'dart:io';

import 'package:io_uring/io_uring.dart';

void main() {
  if (!Platform.isLinux) {
    stderr.writeln('io_uring is Linux-only; run this example in WSL or Linux.');
    exitCode = 1;
    return;
  }

  final directory = Directory.systemTemp.createTempSync('io_uring_example_');
  final file = File('${directory.path}/hello.txt')
    ..writeAsStringSync('hello from io_uring\n');

  final ring = IoUring(entries: 8);
  final buffer = UringBuffer.allocate(256);
  final fd = Posix.open(file.path);

  try {
    ring.push(
      ReadOp(fd: fd, buffer: buffer.pointer, length: buffer.length),
      userData: 1,
    );
    ring.submitAndWait(1);

    final cqe = ring.waitCqe();
    if (cqe.isError) {
      stderr.writeln('read failed with errno ${cqe.errno}');
      exitCode = 1;
      return;
    }
    stdout.write(utf8.decode(buffer.bytes.sublist(0, cqe.result)));
    stdout.writeln('ring: $ring');
  } finally {
    ring.close();
    buffer.dispose();
    Posix.close(fd);
    directory.deleteSync(recursive: true);
  }
}
