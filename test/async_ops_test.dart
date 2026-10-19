@TestOn('linux')
library;

import 'dart:ffi';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

List<IoUringCompletion> _drain(IoUring ring, int count) {
  final completions = <IoUringCompletion>[];
  while (completions.length < count) {
    completions.add(ring.waitCqe());
  }
  return completions;
}

Map<int, IoUringCompletion> _byUserData(List<IoUringCompletion> completions) =>
    {for (final completion in completions) completion.userData: completion};

void main() {
  test('linked NOPs all complete', () {
    final ring = IoUring(entries: 8);
    try {
      ring.push(const NopOp(), userData: 1, sqeFlags: IoUringSqeFlags.ioLink);
      ring.push(const NopOp(), userData: 2);
      ring.submitAndWait(2);

      final completions = _drain(ring, 2);
      expect(completions.every((cqe) => cqe.result == 0), isTrue);
      expect(completions.map((cqe) => cqe.userData), containsAll([1, 2]));
    } finally {
      ring.close();
    }
  });

  test('a failing link cancels the rest of the chain', () {
    final ring = IoUring(entries: 8);
    final buffer = UringBuffer.allocate(8);
    try {
      ring.push(
        ReadOp(fd: -1, buffer: buffer.pointer, length: 8),
        userData: 10,
        sqeFlags: IoUringSqeFlags.ioLink,
      );
      ring.push(const NopOp(), userData: 11);
      ring.submitAndWait(2);

      final byUserData = _byUserData(_drain(ring, 2));
      expect(byUserData[10]!.result, -9); // -EBADF
      expect(byUserData[11]!.result, -125); // -ECANCELED
    } finally {
      ring.close();
      buffer.dispose();
    }
  });

  test('timeout expires with -ETIME', () {
    final ring = IoUring(entries: 8);
    final timespec = UringTimespec.milliseconds(10);
    try {
      ring.push(TimeoutOp(timespec: timespec), userData: 20);
      ring.submitAndWait(1);

      final cqe = ring.waitCqe();
      expect(cqe.userData, 20);
      expect(cqe.result, -62); // -ETIME
    } finally {
      ring.close();
      timespec.dispose();
    }
  });

  test('TIMEOUT_REMOVE cancels a pending timeout', () {
    final ring = IoUring(entries: 8);
    final timespec = UringTimespec.milliseconds(10000);
    try {
      ring.push(TimeoutOp(timespec: timespec), userData: 30);
      ring.submit();

      ring.push(TimeoutRemoveOp(userData: 30), userData: 31);
      ring.submitAndWait(1);

      final byUserData = _byUserData(_drain(ring, 2));
      expect(byUserData[31]!.result, 0);
      expect(byUserData[30]!.result, -125); // -ECANCELED
    } finally {
      ring.close();
      timespec.dispose();
    }
  });

  test('ASYNC_CANCEL cancels by user_data', () {
    final ring = IoUring(entries: 8);
    final timespec = UringTimespec.milliseconds(10000);
    try {
      ring.push(TimeoutOp(timespec: timespec), userData: 40);
      ring.submit();

      ring.push(AsyncCancelOp(userData: 40), userData: 41);
      ring.submitAndWait(1);

      final byUserData = _byUserData(_drain(ring, 2));
      expect(byUserData[41]!.result, 0);
      expect(byUserData[40]!.result, -125); // -ECANCELED
    } finally {
      ring.close();
      timespec.dispose();
    }
  });

  test('POLL_ADD completes when an eventfd is signaled', () {
    final ring = IoUring(entries: 8);
    final eventfd = Posix.eventfd();
    final value = UringBuffer.allocate(8);
    value.pointer.cast<Uint64>().value = 1;
    try {
      ring.push(
        PollAddOp(fd: eventfd, events: PollEvents.pollIn),
        userData: 50,
      );
      ring.submit();

      expect(Posix.write(eventfd, value.pointer, 8), 8);
      final cqe = ring.waitCqe();
      expect(cqe.userData, 50);
      expect(cqe.result & PollEvents.pollIn, PollEvents.pollIn);
    } finally {
      ring.close();
      value.dispose();
      Posix.close(eventfd);
    }
  });

  test('POLL_REMOVE cancels a pending poll', () {
    final ring = IoUring(entries: 8);
    final pipe = Posix.pipe2();
    try {
      ring.push(
        PollAddOp(fd: pipe.readFd, events: PollEvents.pollIn),
        userData: 60,
      );
      ring.submit();

      ring.push(PollRemoveOp(userData: 60), userData: 61);
      ring.submitAndWait(1);

      final byUserData = _byUserData(_drain(ring, 2));
      expect(byUserData[61]!.result, 0);
      expect(byUserData[60]!.result, -125); // -ECANCELED
    } finally {
      ring.close();
      pipe.close();
    }
  });

  test('LINK_TIMEOUT cancels a blocked linked request', () {
    final ring = IoUring(entries: 8);
    final pipe = Posix.pipe2();
    final timespec = UringTimespec.milliseconds(10);
    try {
      ring.push(
        PollAddOp(fd: pipe.readFd, events: PollEvents.pollIn),
        userData: 70,
        sqeFlags: IoUringSqeFlags.ioLink,
      );
      ring.push(LinkTimeoutOp(timespec: timespec), userData: 71);
      ring.submitAndWait(2);

      final byUserData = _byUserData(_drain(ring, 2));
      expect(byUserData[70]!.result, -125); // -ECANCELED
      expect(byUserData[71]!.result, -62); // -ETIME
    } finally {
      ring.close();
      timespec.dispose();
      pipe.close();
    }
  });
}
