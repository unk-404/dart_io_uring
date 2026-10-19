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
    directory = Directory.systemTemp.createTempSync('dart_io_uring_fileops_');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('OPENAT / READ / CLOSE through the ring', () {
    final file = File('${directory.path}/data.txt')
      ..writeAsStringSync('opened via ring');
    final ring = IoUring(entries: 8);
    final path = UringPath(file.path);
    final buffer = UringBuffer.allocate(64);
    try {
      ring.push(OpenAtOp(path: path), userData: 1);
      ring.submitAndWait(1);
      final openCqe = ring.waitCqe();
      expect(openCqe.isError, isFalse);
      final fd = openCqe.result;
      expect(fd, greaterThanOrEqualTo(0));

      ring.push(
        ReadOp(fd: fd, buffer: buffer.pointer, length: 64, offset: 0),
        userData: 2,
      );
      ring.submitAndWait(1);
      final readCqe = ring.waitCqe();
      expect(readCqe.result, 15);
      expect(
        utf8.decode(buffer.bytes.sublist(0, readCqe.result)),
        'opened via ring',
      );

      ring.push(CloseOp(fd: fd), userData: 3);
      ring.submitAndWait(1);
      expect(ring.waitCqe().result, 0);
    } finally {
      ring.close();
      path.dispose();
      buffer.dispose();
    }
  });

  test('OPENAT creates a file and carries the mode', () {
    final file = File('${directory.path}/created.txt');
    final ring = IoUring(entries: 8);
    final path = UringPath(file.path);
    try {
      ring.push(
        OpenAtOp(
          path: path,
          flags:
              PosixConstants.oRdwr |
              PosixConstants.oCreat |
              PosixConstants.oTrunc,
          mode: 0x1A4, // 0644
        ),
        userData: 9,
      );
      ring.submitAndWait(1);
      final openCqe = ring.waitCqe();
      expect(openCqe.isError, isFalse);
      final fd = openCqe.result;
      expect(fd, greaterThanOrEqualTo(0));

      ring.push(CloseOp(fd: fd), userData: 10);
      ring.submitAndWait(1);
      expect(ring.waitCqe().result, 0);

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), 0);
    } finally {
      ring.close();
      path.dispose();
    }
  });

  test('FTRUNCATE shrinks a file', () {
    final file = File('${directory.path}/truncate.txt')
      ..writeAsStringSync('0123456789');
    final ring = IoUring(entries: 8);
    final fd = Posix.open(file.path, flags: PosixConstants.oRdwr);
    try {
      ring.push(FtruncateOp(fd: fd, length: 4), userData: 4);
      ring.submitAndWait(1);
      expect(ring.waitCqe().result, 0);
      expect(file.lengthSync(), 4);
    } finally {
      ring.close();
      Posix.close(fd);
    }
  });

  test('FALLOCATE extends a file', () {
    final file = File('${directory.path}/fallocate.txt')
      ..writeAsStringSync('x');
    final ring = IoUring(entries: 8);
    final fd = Posix.open(file.path, flags: PosixConstants.oRdwr);
    try {
      ring.push(FallocateOp(fd: fd, length: 4096), userData: 5);
      ring.submitAndWait(1);
      final cqe = ring.waitCqe();
      expect(cqe.result, 0);
      expect(file.lengthSync(), 4096);
    } finally {
      ring.close();
      Posix.close(fd);
    }
  });

  test('WRITEV / READV round-trip', () {
    final file = File('${directory.path}/vectored.txt');
    final ring = IoUring(entries: 8);
    final fd = Posix.open(
      file.path,
      flags:
          PosixConstants.oRdwr | PosixConstants.oCreat | PosixConstants.oTrunc,
      mode: 0x1A4,
    );
    final first = UringBuffer.allocate(8);
    final second = UringBuffer.allocate(8);
    final hello = utf8.encode('hello ');
    final world = utf8.encode('world');
    first.bytes.setRange(0, hello.length, hello);
    second.bytes.setRange(0, world.length, world);

    final writeVecs = UringIoVecList([
      UringIoVec(buffer: first.pointer, length: hello.length),
      UringIoVec(buffer: second.pointer, length: world.length),
    ]);
    try {
      ring.push(WritevOp(fd: fd, iovecs: writeVecs, offset: 0), userData: 6);
      ring.submitAndWait(1);
      expect(ring.waitCqe().result, 11);

      first.bytes.fillRange(0, first.length, 0);
      second.bytes.fillRange(0, second.length, 0);

      final readVecs = UringIoVecList([
        UringIoVec(buffer: first.pointer, length: hello.length),
        UringIoVec(buffer: second.pointer, length: world.length),
      ]);
      try {
        ring.push(ReadvOp(fd: fd, iovecs: readVecs, offset: 0), userData: 7);
        ring.submitAndWait(1);
        expect(ring.waitCqe().result, 11);
        final bytes = <int>[
          ...first.bytes.sublist(0, hello.length),
          ...second.bytes.sublist(0, world.length),
        ];
        expect(utf8.decode(bytes), 'hello world');
      } finally {
        readVecs.dispose();
      }
    } finally {
      writeVecs.dispose();
      ring.close();
      second.dispose();
      first.dispose();
      Posix.close(fd);
    }
  });

  test('STATX fills a statx buffer', () {
    final file = File('${directory.path}/statx.txt')
      ..writeAsStringSync('stat me');
    final ring = IoUring(entries: 8);
    final path = UringPath(file.path);
    final statx = UringBuffer.allocate(256);
    try {
      ring.push(StatxOp(path: path, statxBuffer: statx.pointer), userData: 8);
      ring.submitAndWait(1);
      final cqe = ring.waitCqe();
      expect(cqe.result, 0);
      // struct statx starts with stx_mask.
      expect(statx.pointer.cast<Uint32>().value, isNot(0));
    } finally {
      ring.close();
      path.dispose();
      statx.dispose();
    }
  });
}
