@TestOn('linux')
library;

import 'dart:ffi';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  test('ring can be created and reports sane parameters', () {
    final ring = IoUring(entries: 8);
    try {
      expect(ring.sqCapacity, 8);
      expect(ring.cqCapacity, greaterThanOrEqualTo(8));
      expect(ring.parameters.hasSingleMmap, isTrue);
      expect(ring.isClosed, isFalse);
    } finally {
      ring.close();
    }
    expect(ring.isClosed, isTrue);
  });

  test('NOP round-trip', () {
    final ring = IoUring(entries: 8);
    try {
      ring.push(const NopOp(), userData: 0x1122334455667788);
      final submitted = ring.submitAndWait(1);
      expect(submitted, 1);

      final cqe = ring.waitCqe();
      expect(cqe.userData, 0x1122334455667788);
      expect(cqe.result, 0);
      expect(cqe.isError, isFalse);
    } finally {
      ring.close();
    }
  });

  test('batched NOPs preserve order and user data', () {
    final ring = IoUring(entries: 8);
    try {
      for (var i = 0; i < 8; i++) {
        ring.push(const NopOp(), userData: 1000 + i);
      }
      ring.submitAndWait(8);

      final seen = <int>[];
      while (true) {
        final cqe = ring.nextCqe();
        if (cqe == null) break;
        expect(cqe.result, 0);
        seen.add(cqe.userData);
      }
      expect(seen, [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007]);
      expect(ring.cqReady, 0);
    } finally {
      ring.close();
    }
  });

  test('queue fills up and drains', () {
    final ring = IoUring(entries: 4);
    try {
      var pushed = 0;
      while (true) {
        final sqe = ring.nextSqe();
        if (sqe == null) break;
        sqe.ref
          ..opcode = IoUringOpcode.nop
          ..fd = -1
          ..userData = pushed;
        pushed++;
        expect(pushed, lessThanOrEqualTo(4));
      }
      expect(pushed, 4);
      expect(ring.sqReady, 4);

      ring.submitAndWait(4);
      for (var i = 0; i < 4; i++) {
        expect(ring.nextCqe()!.userData, i);
      }
      expect(ring.sqFree, 4);
    } finally {
      ring.close();
    }
  });

  test('double close is safe', () {
    final ring = IoUring(entries: 2);
    ring.close();
    ring.close();
    expect(ring.isClosed, isTrue);
  });

  test('many submit/reap cycles reuse SQE slots', () {
    final ring = IoUring(entries: 8);
    try {
      var userData = 0;
      for (var round = 0; round < 20; round++) {
        for (var i = 0; i < 8; i++) {
          ring.push(const NopOp(), userData: userData++);
        }
        ring.submitAndWait(8);
        for (var i = 0; i < 8; i++) {
          final cqe = ring.waitCqe();
          expect(cqe.result, 0);
        }
      }
      expect(ring.sqFree, 8);
    } finally {
      ring.close();
    }
  });

  test('failed operation reports a negative errno in the CQE', () {
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(16);
    try {
      ring.push(
        ReadOp(fd: -1, buffer: buffer.pointer, length: 16),
        userData: 9,
      );
      ring.submitAndWait(1);
      final cqe = ring.waitCqe();
      expect(cqe.isError, isTrue);
      expect(cqe.errno, 9); // EBADF
    } finally {
      ring.close();
      buffer.dispose();
    }
  });

  test('multiple rings coexist', () {
    final rings = <IoUring>[];
    try {
      for (var i = 0; i < 3; i++) {
        final ring = IoUring(entries: 4);
        rings.add(ring);
        ring.push(const NopOp(), userData: i);
        ring.submitAndWait(1);
        expect(ring.waitCqe().userData, i);
      }
    } finally {
      for (final ring in rings.reversed) {
        ring.close();
      }
    }
  });

  test('custom CQ size is honored', () {
    final ring = IoUring(entries: 4, cqEntries: 32);
    try {
      expect(ring.sqCapacity, 4);
      expect(ring.cqCapacity, 32);
      expect(ring.parameters.flags & IoUringSetupFlags.cqsize, isNot(0));
    } finally {
      ring.close();
    }
  });

  test('submit without waiting, then block for the CQE', () {
    final ring = IoUring(entries: 4);
    try {
      ring.push(const NopOp(), userData: 0x55);
      expect(ring.sqReady, 1);
      expect(ring.submit(), 1);
      expect(ring.sqReady, 0);

      final cqe = ring.waitCqe();
      expect(cqe.userData, 0x55);
      expect(cqe.result, 0);
      expect(ring.nextCqe(), isNull);
    } finally {
      ring.close();
    }
  });

  test('reapCqes copies raw CQEs without allocating', () {
    final ring = IoUring(entries: 8);
    final raw = UringBuffer.allocate(4 * 16);
    try {
      for (var i = 0; i < 4; i++) {
        ring.push(const NopOp(), userData: 100 + i);
      }
      ring.submitAndWait(4);
      expect(ring.reapCqes(raw.pointer, 4), 4);

      final words = raw.pointer.cast<Uint64>();
      final values = raw.pointer.cast<Int32>();
      for (var i = 0; i < 4; i++) {
        expect((words + i * 2).value, 100 + i);
        expect((values + i * 4 + 2).value, 0); // res at byte offset 8
      }
      expect(ring.nextCqe(), isNull);
    } finally {
      ring.close();
      raw.dispose();
    }
  });
}
