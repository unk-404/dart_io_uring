@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  test('Future API completes a NOP', () async {
    final loop = await UringLoop.open(entries: 16);
    try {
      final cqe = await loop.run(const NopOp());
      expect(cqe.isError, isFalse);
      expect(cqe.result, 0);
    } finally {
      await loop.close();
    }
  });

  test('Future API handles concurrent submissions', () async {
    final loop = await UringLoop.open(entries: 64);
    try {
      final futures = [for (var i = 0; i < 32; i++) loop.run(const NopOp())];
      final completions = await Future.wait(futures);
      expect(completions.length, 32);
      expect(completions.every((cqe) => cqe.result == 0), isTrue);
    } finally {
      await loop.close();
    }
  });

  test('runAll batches submissions', () async {
    final loop = await UringLoop.open(entries: 32);
    try {
      final futures = loop.runAll(List<UringOp>.filled(16, const NopOp()));
      final completions = await Future.wait(futures);
      expect(completions.length, 16);
      expect(completions.every((cqe) => cqe.result == 0), isTrue);
    } finally {
      await loop.close();
    }
  });

  test('Future API reads a file', () async {
    final directory = Directory.systemTemp.createTempSync(
      'dart_io_uring_async_',
    );
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('async io_uring');
    final fd = Posix.open(file.path);
    final buffer = UringBuffer.allocate(64);
    final loop = await UringLoop.open(entries: 8);
    try {
      final cqe = await loop.run(
        ReadOp(fd: fd, buffer: buffer.pointer, length: 64),
      );
      expect(cqe.result, 14);
      expect(
        utf8.decode(buffer.bytes.sublist(0, cqe.result)),
        'async io_uring',
      );
    } finally {
      await loop.close();
      buffer.dispose();
      Posix.close(fd);
      directory.deleteSync(recursive: true);
    }
  });

  test('close fails pending futures', () async {
    final loop = await UringLoop.open(entries: 8);
    final timespec = UringTimespec.milliseconds(60000);
    final future = loop.run(TimeoutOp(timespec: timespec));
    final expectation = expectLater(future, throwsA(isA<StateError>()));
    await loop.close();
    await expectation;
    timespec.dispose();
  });
}
