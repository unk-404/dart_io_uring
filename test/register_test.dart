@TestOn('linux')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('dart_io_uring_register_');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('registered buffer works with READ_FIXED', () {
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('hello fixed');
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    final spare = UringBuffer.allocate(64);
    final fd = Posix.open(file.path);
    ring.registerBuffers([buffer, spare]);
    try {
      ring.push(
        ReadFixedOp(
          fd: fd,
          buffer: spare.pointer,
          length: 64,
          bufIndex: 1,
          offset: 0,
        ),
        userData: 1,
      );
      ring.submitAndWait(1);

      final cqe = ring.waitCqe();
      expect(cqe.result, 11);
      expect(utf8.decode(spare.bytes.sublist(0, cqe.result)), 'hello fixed');
      expect(buffer.bytes.sublist(0, 11), everyElement(0));
      ring.unregisterBuffers();
    } finally {
      ring.close();
      spare.dispose();
      buffer.dispose();
      Posix.close(fd);
    }
  });

  test('registered file works with IOSQE_FIXED_FILE', () {
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('registered fd');
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    final fd = Posix.open(file.path);
    ring.registerFiles([fd]);
    try {
      ring.push(
        ReadOp(
          fd: 0,
          buffer: buffer.pointer,
          length: 64,
          offset: 0,
          fixedFile: true,
        ),
        userData: 2,
      );
      ring.submitAndWait(1);

      final cqe = ring.waitCqe();
      expect(cqe.result, 13);
      expect(utf8.decode(buffer.bytes.sublist(0, cqe.result)), 'registered fd');
      ring.unregisterFiles();
    } finally {
      ring.close();
      buffer.dispose();
      Posix.close(fd);
    }
  });

  test('eventfd is signaled for posted completions', () {
    const efdNonblock = 0x800;
    final ring = IoUring(entries: 8);
    final eventfd = Posix.eventfd(flags: efdNonblock);
    final countBuffer = UringBuffer.allocate(8);
    try {
      ring.registerEventfd(eventfd);
      ring.push(const NopOp(), userData: 3);
      ring.submitAndWait(1);
      expect(ring.waitCqe().userData, 3);

      final read = Posix.read(eventfd, countBuffer.pointer, 8);
      expect(read, 8);
      expect(countBuffer.pointer.cast<Uint64>().value, greaterThanOrEqualTo(1));
      ring.unregisterEventfd();
    } finally {
      ring.close();
      countBuffer.dispose();
      Posix.close(eventfd);
    }
  });
}
