@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

IoUringCompletion _call(IoUring ring, UringOp operation, {int userData = 0}) {
  ring.push(operation, userData: userData);
  ring.submitAndWait(1);
  return ring.waitCqe();
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('dart_io_uring_pipe_');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('SPLICE copies pipe data into a file', () {
    final pipe = Posix.pipe2();
    final file = File('${directory.path}/splice.txt');
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    var fd = -1;
    try {
      final payload = utf8.encode('splice me');
      buffer.bytes.setRange(0, payload.length, payload);
      expect(
        Posix.write(pipe.writeFd, buffer.pointer, payload.length),
        payload.length,
      );

      fd = Posix.open(
        file.path,
        flags:
            PosixConstants.oWronly |
            PosixConstants.oCreat |
            PosixConstants.oTrunc,
        mode: 0x1A4,
      );
      final cqe = _call(
        ring,
        SpliceOp(
          fdIn: pipe.readFd,
          fdOut: fd,
          length: payload.length,
          offOut: 0,
        ),
        userData: 1,
      );
      expect(cqe.result, payload.length, reason: 'SPLICE: $cqe');
      expect(file.readAsStringSync(), 'splice me');
    } finally {
      ring.close();
      buffer.dispose();
      if (fd >= 0) {
        Posix.close(fd);
      }
      pipe.close();
    }
  });

  test('TEE duplicates pipe data without consuming the source', () {
    final source = Posix.pipe2();
    final target = Posix.pipe2();
    final ring = IoUring(entries: 8);
    final inBuffer = UringBuffer.allocate(64);
    final outBuffer = UringBuffer.allocate(64);
    try {
      final payload = utf8.encode('tee me!');
      inBuffer.bytes.setRange(0, payload.length, payload);
      expect(
        Posix.write(source.writeFd, inBuffer.pointer, payload.length),
        payload.length,
      );

      final cqe = _call(
        ring,
        TeeOp(
          fdIn: source.readFd,
          fdOut: target.writeFd,
          length: payload.length,
        ),
        userData: 2,
      );
      expect(cqe.result, payload.length, reason: 'TEE: $cqe');

      final targetBytes = Posix.read(target.readFd, outBuffer.pointer, 64);
      expect(utf8.decode(outBuffer.bytes.sublist(0, targetBytes)), 'tee me!');

      final sourceBytes = Posix.read(source.readFd, outBuffer.pointer, 64);
      expect(utf8.decode(outBuffer.bytes.sublist(0, sourceBytes)), 'tee me!');
    } finally {
      ring.close();
      inBuffer.dispose();
      outBuffer.dispose();
      source.close();
      target.close();
    }
  });
}
