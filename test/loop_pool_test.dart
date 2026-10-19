@TestOn('linux')
library;

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

void main() {
  test('pool reuses an idle loop', () async {
    final pool = UringLoopPool(entries: 8);
    addTearDown(pool.close);

    final first = await pool.acquire();
    final loop = first.loop;
    final completion = await loop.run(const NopOp());
    expect(completion.result, 0);
    await first.release();

    final second = await pool.acquire();
    expect(identical(second.loop, loop), isTrue);
    await second.release();
  });

  test('concurrent leases never share a loop', () async {
    final pool = UringLoopPool(entries: 8);
    addTearDown(pool.close);

    final first = await pool.acquire();
    final second = await pool.acquire();
    expect(identical(first.loop, second.loop), isFalse);
    await first.release();
    await second.release();
  });

  test('close waits for active leases', () async {
    final pool = UringLoopPool(entries: 8);
    final first = await pool.acquire();
    final second = await pool.acquire();

    var closed = false;
    final closing = pool.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);

    await first.release();
    expect(closed, isFalse);

    await second.release();
    await closing;
    expect(closed, isTrue);
    expect(pool.isClosed, isTrue);
  });

  test('release is single-use', () async {
    final pool = UringLoopPool(entries: 8);
    addTearDown(pool.close);

    final lease = await pool.acquire();
    await lease.release();
    expect(lease.isReleased, isTrue);
    await expectLater(lease.release(), throwsStateError);
  });

  test('closed loops are discarded instead of reused', () async {
    final pool = UringLoopPool(entries: 8);
    addTearDown(pool.close);

    final first = await pool.acquire();
    final old = first.loop;
    await old.close();
    await first.release();

    final second = await pool.acquire();
    expect(identical(second.loop, old), isFalse);
    await second.release();
  });

  test('UringLoop.acquire uses the shared pool', () async {
    final pool = UringLoopPool.shared(entries: 64);
    addTearDown(pool.close);

    final lease = await UringLoop.acquire(entries: 64);
    expect(lease.loop.reaperError, isNull);
    final completion = await lease.loop.run(const NopOp());
    expect(completion.result, 0);
    await lease.release();
  });

  test('closed pool rejects new leases', () async {
    final pool = UringLoopPool(entries: 8);
    await pool.close();
    expect(pool.isClosed, isTrue);
    await expectLater(pool.acquire(), throwsStateError);
  });

  test('health getters start clean', () async {
    final pool = UringLoopPool(entries: 8);
    addTearDown(pool.close);
    final lease = await pool.acquire();
    expect(lease.loop.hasError, isFalse);
    expect(lease.loop.reaperError, isNull);
    await lease.release();
  });

  test('spin reaper completes a NOP and closes', () async {
    final loop = await UringLoop.open(entries: 8, spin: true);
    try {
      final completion = await loop.run(const NopOp());
      expect(completion.result, 0);
    } finally {
      await loop.close();
    }
  });

  test('spin pool handles runAll', () async {
    final pool = UringLoopPool(entries: 8, spin: true);
    addTearDown(pool.close);
    final lease = await pool.acquire();
    final completions = await Future.wait(
      lease.loop.runAll(List<UringOp>.filled(4, const NopOp())),
    );
    expect(completions.map((cqe) => cqe.result), everyElement(0));
    await lease.release();
  });
}
