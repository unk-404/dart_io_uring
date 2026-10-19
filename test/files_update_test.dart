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
    directory = Directory.systemTemp.createTempSync('dart_io_uring_files_');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  test('registerFilesUpdate swaps a registered fd', () {
    final fileA = File('${directory.path}/a.txt')..writeAsStringSync('file A');
    final fileB = File('${directory.path}/b.txt')..writeAsStringSync('file B');
    final fileC = File('${directory.path}/c.txt')..writeAsStringSync('file C');

    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(64);
    final fdA = Posix.open(fileA.path);
    final fdB = Posix.open(fileB.path);
    final fdC = Posix.open(fileC.path);

    String readFixed(int index) {
      ring.push(
        ReadOp(fd: index, buffer: buffer.pointer, length: 64, fixedFile: true),
      );
      ring.submitAndWait(1);
      final cqe = ring.waitCqe();
      expect(cqe.isError, isFalse, reason: 'READ fixed[$index]: $cqe');
      return utf8.decode(buffer.bytes.sublist(0, cqe.result));
    }

    try {
      ring.registerFiles([fdA, fdB]);
      expect(readFixed(0), 'file A');
      expect(readFixed(1), 'file B');

      ring.registerFilesUpdate(0, [fdC]);
      expect(readFixed(0), 'file C');
      expect(readFixed(1), 'file B');

      final fdsBuffer = UringBuffer.allocate(4);
      try {
        fdsBuffer.pointer.cast<Int32>().value = fdA;
        ring.push(
          FilesUpdateOp(
            fds: fdsBuffer.pointer.cast<Int32>(),
            count: 1,
            offset: 0,
          ),
        );
        ring.submitAndWait(1);
        expect(ring.waitCqe().result, 1); // files updated
        expect(readFixed(0), 'file A');
      } finally {
        fdsBuffer.dispose();
      }

      ring.unregisterFiles();
    } finally {
      ring.close();
      buffer.dispose();
      Posix.close(fdC);
      Posix.close(fdB);
      Posix.close(fdA);
    }
  });
}
