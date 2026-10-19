@TestOn('linux')
library;

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  test('probe reports core operations', () {
    final ring = IoUring(entries: 8);
    try {
      final probe = ring.probe();
      expect(probe.isSupported(IoUringOpcode.nop), isTrue);
      expect(probe.isSupported(IoUringOpcode.read), isTrue);
      expect(probe.isSupported(IoUringOpcode.write), isTrue);
      expect(probe.isSupported(IoUringOpcode.fsync), isTrue);
      expect(probe.isSupported(IoUringOpcode.openat), isTrue);
      expect(probe.lastOp, greaterThanOrEqualTo(IoUringOpcode.openat));
      expect(probe.isSupported(250), isFalse);
    } finally {
      ring.close();
    }
  });

  test('probe result can be queried per opcode', () {
    final ring = IoUring(entries: 4);
    try {
      final probe = ring.probe(maxOps: 64);
      expect(probe.ops, isNotEmpty);
      expect(probe.flagsOf(IoUringOpcode.nop), isA<int>());
    } finally {
      ring.close();
    }
  });
}
