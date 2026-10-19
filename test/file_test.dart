@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('dart_io_uring_test_');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('READ a file', () {
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('hello io_uring');
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    final fd = Posix.open(file.path, flags: PosixConstants.oRdonly);
    try {
      ring.push(
        ReadOp(fd: fd, buffer: buffer.pointer, length: 64, offset: 0),
        userData: 1,
      );
      ring.submitAndWait(1);

      final cqe = ring.waitCqe();
      expect(cqe.result, 14);
      expect(
        utf8.decode(buffer.bytes.sublist(0, cqe.result)),
        'hello io_uring',
      );
    } finally {
      ring.close();
      buffer.dispose();
      Posix.close(fd);
    }
  });

  test('READ at an offset', () {
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('hello io_uring');
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    final fd = Posix.open(file.path);
    try {
      ring.push(
        ReadOp(fd: fd, buffer: buffer.pointer, length: 64, offset: 6),
        userData: 2,
      );
      ring.submitAndWait(1);

      final cqe = ring.waitCqe();
      expect(cqe.result, 8);
      expect(utf8.decode(buffer.bytes.sublist(0, cqe.result)), 'io_uring');
    } finally {
      ring.close();
      buffer.dispose();
      Posix.close(fd);
    }
  });

  test('WRITE then read it back', () {
    final path = '${directory.path}/out.txt';
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(32);
    final payload = utf8.encode('written through io_uring');
    buffer.bytes.setRange(0, payload.length, payload);

    final fd = Posix.open(
      path,
      flags:
          PosixConstants.oRdwr | PosixConstants.oCreat | PosixConstants.oTrunc,
      mode: 0x1A4, // 0644
    );
    try {
      ring.push(
        WriteOp(fd: fd, buffer: buffer.pointer, length: payload.length),
        userData: 3,
      );
      ring.submitAndWait(1);
      final writeCqe = ring.waitCqe();
      expect(writeCqe.result, payload.length);
    } finally {
      ring.close();
      buffer.dispose();
      Posix.close(fd);
    }

    expect(File(path).readAsStringSync(), 'written through io_uring');
  });

  test('fsync completes', () {
    final path = '${directory.path}/fsync.txt';
    final file = File(path)..writeAsStringSync('sync me');
    final ring = IoUring(entries: 8);
    final fd = Posix.open(file.path, flags: PosixConstants.oRdwr);
    try {
      ring.push(FsyncOp(fd: fd), userData: 4);
      ring.submitAndWait(1);
      expect(ring.waitCqe().result, 0);
    } finally {
      ring.close();
      Posix.close(fd);
    }
  });
}
