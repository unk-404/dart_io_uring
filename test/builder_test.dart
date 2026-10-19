@TestOn('linux')
library;

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  test('builder sets setup flags and CQ size', () {
    final ring = IoUringBuilder().entries(4).cqsize(32).coopTaskrun().build();
    try {
      expect(ring.sqCapacity, 4);
      expect(ring.cqCapacity, 32);
      expect(ring.parameters.flags & IoUringSetupFlags.cqsize, isNot(0));
      expect(ring.parameters.flags & IoUringSetupFlags.coopTaskrun, isNot(0));
    } finally {
      ring.close();
    }
  });

  test('SQPOLL ring completes a NOP', () {
    IoUring? ring;
    try {
      ring = IoUringBuilder().entries(8).sqpoll(idle: 1000).build();
    } on IoUringException catch (error) {
      if (error.errno == 1 || error.errno == 13) {
        markTestSkipped('SQPOLL requires privileges: $error');
        return;
      }
      rethrow;
    }
    try {
      ring.push(const NopOp(), userData: 1);
      expect(ring.submit(), 1);
      final cqe = ring.waitCqe();
      expect(cqe.userData, 1);
      expect(cqe.result, 0);

      ring.push(const NopOp(), userData: 2);
      expect(ring.submitAndWait(1), 1);
      final second = ring.waitCqe();
      expect(second.userData, 2);
      expect(second.result, 0);
    } finally {
      ring.close();
    }
  });

  test('IOPOLL setup succeeds when the kernel allows it', () {
    try {
      final ring = IoUringBuilder().entries(4).iopoll().build();
      try {
        expect(ring.parameters.isSetupIopoll, isTrue);
      } finally {
        ring.close();
      }
    } on IoUringException catch (error) {
      if (error.errno == 1 || error.errno == 13 || error.errno == 22) {
        markTestSkipped('IOPOLL not available here: $error');
        return;
      }
      rethrow;
    }
  });
}
