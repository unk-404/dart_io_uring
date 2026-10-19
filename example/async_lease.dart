import 'package:io_uring/io_uring.dart';

Future<void> main() async {
  final lease = await UringLoop.acquire(entries: 256);
  try {
    // The loop is exclusive to this lease until release().
    print('ring sqCapacity=${lease.loop.ring.sqCapacity}');
    final cqe = await lease.loop.run(const NopOp());
    print('NOP result=${cqe.result} flags=${cqe.flags}');
  } finally {
    await lease.release();
  }

  // The shared pool keeps the idle loop for reuse; close it on shutdown.
  await UringLoopPool.shared(entries: 256).close();
}
