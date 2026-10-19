import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import '../errors.dart';
import '../ffi/constants.dart';
import '../ffi/libc.dart';
import '../ffi/memory_barrier.dart';
import '../ops/op.dart';
import '../ring/cqe.dart';
import '../ring/io_uring.dart';
import 'layout.dart';

const int _shutdownUserData = -1;
const int _errorUserData = -2;

final class _ReaperConfig {
  const _ReaperConfig({
    required this.fd,
    required this.layout,
    required this.completions,
    required this.spin,
  });

  final int fd;
  final IoUringAsyncLayout layout;
  final SendPort completions;
  final bool spin;
}

void _reaperMain(_ReaperConfig config) {
  final libc = Libc.instance;
  final barrier = MemoryBarrier.create();
  final cqRing = Pointer<Uint8>.fromAddress(config.layout.cqRingAddress);
  final headPointer = (cqRing + config.layout.cqHeadOffset).cast<Uint32>();
  final tailPointer = (cqRing + config.layout.cqTailOffset).cast<Uint32>();
  final cqes = cqRing + config.layout.cqesOffset;
  final mask = config.layout.cqMask;
  final cqeSize = config.layout.cqeSize;

  var head = headPointer.value;

  bool drain(int tail) {
    barrier.acquire();
    final batch = <int>[];
    var shutdown = false;
    while (head != tail) {
      final cqe = (cqes + (head & mask) * cqeSize).cast<IoUringCqe>().ref;
      final userData = cqe.userData;
      final result = cqe.res;
      final flags = cqe.flags;
      head = (head + 1) & 0xFFFFFFFF;
      if (userData == _shutdownUserData) {
        shutdown = true;
        continue;
      }
      batch
        ..add(userData)
        ..add(result)
        ..add(flags);
    }

    barrier.release();
    headPointer.value = head;
    if (batch.isNotEmpty) {
      config.completions.send(batch);
    }
    return shutdown;
  }

  if (config.spin) {
    // Latency mode: keep the reaper hot on the CQ tail instead of entering the
    // kernel and waiting to be woken. This consumes a core while idle.
    while (true) {
      final tail = tailPointer.value;
      if (head == tail) {
        continue;
      }
      if (drain(tail)) {
        config.completions.send(<int>[_shutdownUserData, 0, 0]);
        return;
      }
    }
  }

  while (true) {
    final entered = libc.syscall6(
      IoUringSyscall.enter,
      config.fd,
      0,
      1,
      IoUringEnterFlags.getEvents,
      0,
      0,
    );
    if (entered < 0) {
      final errno = libc.errno;
      if (errno == 4) {
        continue; // EINTR
      }
      config.completions.send(<int>[_errorUserData, errno, 0]);
      return;
    }

    final tail = tailPointer.value;
    if (drain(tail)) {
      config.completions.send(<int>[_shutdownUserData, 0, 0]);
      return;
    }
  }
}

/// A Future-based wrapper around [IoUring] with a dedicated reaper isolate.
///
/// The owner isolate submits directly (no message hop); a reaper isolate blocks
/// in `io_uring_enter(GETEVENTS)` and funnels completed CQEs back. The owner
/// must not call [IoUring.waitCqe] / [IoUring.nextCqe] while the loop is
/// active; submissions and registration on [ring] are fine.
final class UringLoop {
  UringLoop._(this._ring, this._layout, this._port);

  final IoUring _ring;
  final IoUringAsyncLayout _layout;
  final RawReceivePort _port;

  late final Isolate _reaper;
  final Map<int, Completer<IoUringCompletion>> _pending = {};
  final Completer<void> _shutdown = Completer<void>();

  int _nextSeq = 1;
  bool _closed = false;
  IoUringException? _reaperError;

  /// The underlying ring. Do not reap completions from it directly.
  IoUring get ring => _ring;

  /// Shared-memory layout used by the reaper.
  IoUringAsyncLayout get layout => _layout;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Last reaper error, if the background isolate failed.
  IoUringException? get reaperError => _reaperError;

  /// Whether the reaper failed and the loop should not be reused.
  bool get hasError => _reaperError != null;

  /// Number of operations waiting for a completion.
  int get pendingCount => _pending.length;

  /// Acquires an exclusive loop lease from the shared [UringLoopPool].
  ///
  /// This is a convenience for short-lived callers. The returned lease must be
  /// released in a `finally` block; see [UringLoopLease.release].
  static Future<UringLoopLease> acquire({
    int entries = 256,
    bool spin = false,
  }) {
    return UringLoopPool.shared(entries: entries, spin: spin).acquire();
  }

  /// Creates a ring and starts its reaper isolate.
  ///
  /// Set [spin] to busy-poll the completion queue instead of blocking in
  /// `io_uring_enter`. Spin mode lowers wake-up latency but consumes a CPU core
  /// while the loop is idle.
  static Future<UringLoop> open({int entries = 256, bool spin = false}) async {
    final ring = IoUring(entries: entries);
    try {
      return await fromRing(ring, spin: spin);
    } on Object {
      ring.close();
      rethrow;
    }
  }

  /// Starts a reaper for an existing ring.
  ///
  /// The ring must not have in-flight operations that the caller will reap
  /// manually; from this point on its CQ is owned by the loop.
  static Future<UringLoop> fromRing(IoUring ring, {bool spin = false}) async {
    final layout = ring.asyncLayout;
    final port = RawReceivePort();
    final loop = UringLoop._(ring, layout, port);
    port.handler = loop._handleMessage;
    try {
      loop._reaper = await Isolate.spawn(
        _reaperMain,
        _ReaperConfig(
          fd: ring.fd,
          layout: layout,
          completions: port.sendPort,
          spin: spin,
        ),
        debugName: 'io_uring-reaper',
      );
    } on Object {
      port.close();
      rethrow;
    }
    return loop;
  }

  /// Submits one operation and completes when its CQE is posted.
  Future<IoUringCompletion> run(UringOp operation) {
    _ensureOpen();
    final reaperError = _reaperError;
    if (reaperError != null) {
      return Future<IoUringCompletion>.error(reaperError);
    }

    final seq = _takeSeq();
    final completer = Completer<IoUringCompletion>.sync();
    _pending[seq] = completer;
    try {
      _ring.push(operation, userData: seq);
      _ring.submit();
    } on Object catch (error, stack) {
      _pending.remove(seq);
      completer.completeError(error, stack);
    }
    return completer.future;
  }

  /// Submits several operations with one `io_uring_enter`.
  List<Future<IoUringCompletion>> runAll(List<UringOp> operations) {
    _ensureOpen();
    if (operations.isEmpty) return const [];

    final reaperError = _reaperError;
    if (reaperError != null) {
      return [
        for (var i = 0; i < operations.length; i++)
          Future<IoUringCompletion>.error(reaperError),
      ];
    }

    final futures = <Future<IoUringCompletion>>[];
    final completers = <Completer<IoUringCompletion>>[];
    final seqs = <int>[];
    for (var i = 0; i < operations.length; i++) {
      final seq = _takeSeq();
      final completer = Completer<IoUringCompletion>.sync();
      _pending[seq] = completer;
      seqs.add(seq);
      completers.add(completer);
      futures.add(completer.future);
    }

    try {
      for (var i = 0; i < operations.length; i++) {
        _ring.push(operations[i], userData: seqs[i]);
      }
      _ring.submit();
    } on Object catch (error, stack) {
      for (final seq in seqs) {
        _pending.remove(seq);
      }
      for (final completer in completers) {
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      }
    }
    return futures;
  }

  /// Stops the reaper, fails pending futures, and closes the ring.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final closedError = StateError('UringLoop is closed');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(closedError);
      }
    }
    _pending.clear();

    var reaperRunning = _reaperError == null;
    if (reaperRunning) {
      try {
        _ring.push(const NopOp(), userData: _shutdownUserData);
        _ring.submit();
        await _shutdown.future.timeout(const Duration(seconds: 5));
      } on Object {
        reaperRunning = false;
      }
    }

    _port.close();
    if (reaperRunning) {
      _reaper.kill(priority: Isolate.immediate);
    }
    _ring.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('UringLoop is closed');
    }
  }

  int _takeSeq() {
    final seq = _nextSeq;
    if (seq <= 0 || seq >= 0x7FFFFFFFFFFFFFFF) {
      throw StateError('UringLoop sequence space exhausted');
    }
    _nextSeq = seq + 1;
    return seq;
  }

  void _handleMessage(Object? message) {
    final List<int> values;
    if (message is List<int>) {
      values = message;
    } else if (message is List) {
      values = message.cast<int>();
    } else {
      return;
    }
    if (values.length < 3) return;

    final first = values[0];
    if (first == _shutdownUserData) {
      if (!_shutdown.isCompleted) {
        _shutdown.complete();
      }
      return;
    }
    if (first == _errorUserData) {
      final error = IoUringException('io_uring reaper', values[1]);
      _reaperError = error;
      for (final completer in _pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
      _pending.clear();
      if (!_shutdown.isCompleted) {
        _shutdown.complete();
      }
      return;
    }

    for (var i = 0; i + 2 < values.length; i += 3) {
      final userData = values[i];
      final completer = _pending.remove(userData);
      if (completer != null && !completer.isCompleted) {
        completer.complete(
          IoUringCompletion(
            userData: userData,
            result: values[i + 1],
            flags: values[i + 2],
          ),
        );
      }
    }
  }
}

/// An exclusive lease on a loop owned by a [UringLoopPool].
///
/// Release it exactly once. After release the loop may be handed to another
/// caller, so do not submit new operations through [loop] afterwards.
final class UringLoopLease {
  UringLoopLease._(this._pool, this.loop);

  final UringLoopPool _pool;

  /// The loop leased to this caller.
  final UringLoop loop;

  bool _released = false;

  /// Whether [release] has been called.
  bool get isReleased => _released;

  /// Returns the loop to the pool (or closes it when the pool is closed).
  Future<void> release() async {
    if (_released) {
      throw StateError('UringLoopLease has already been released');
    }
    _released = true;
    await _pool._release(this);
  }
}

/// A small pool of [UringLoop]s with exclusive leases.
///
/// The pool creates a loop on demand, reuses idle loops, and closes them when
/// [close] is called. It only manages ring/reaper lifecycle and reference
/// counting; it has no file, buffer, or registration policy. A returned loop is
/// exclusive to one lease at a time, but registrations made on it persist across
/// leases.
final class UringLoopPool {
  /// Creates an empty pool for rings with [entries] SQ entries.
  ///
  /// Set [spin] to use the busy-poll reaper for pooled loops.
  UringLoopPool({this.entries = 256, this.spin = false}) {
    if (entries <= 0) {
      throw ArgumentError.value(entries, 'entries', 'must be positive');
    }
  }

  /// SQ entries for newly created loops.
  final int entries;

  /// Whether pooled loops use the low-latency busy-poll reaper.
  final bool spin;

  final List<UringLoop> _idle = [];
  int _active = 0;
  bool _closed = false;
  Completer<void>? _closeCompleter;

  static final Map<String, UringLoopPool> _shared = {};

  /// Returns the process-wide pool for [entries] and [spin].
  ///
  /// A new pool is created if the previous one was closed.
  static UringLoopPool shared({int entries = 256, bool spin = false}) {
    final key = '$entries:$spin';
    final existing = _shared[key];
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    final pool = UringLoopPool(entries: entries, spin: spin);
    _shared[key] = pool;
    return pool;
  }

  /// Number of leases currently checked out.
  int get activeLeases => _active;

  /// Number of idle loops available for reuse.
  int get idleLoops => _idle.length;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Takes an idle loop or creates one.
  Future<UringLoopLease> acquire() async {
    if (_closed) {
      throw StateError('UringLoopPool is closed');
    }

    UringLoop? loop;
    while (_idle.isNotEmpty) {
      final candidate = _idle.removeLast();
      if (candidate.isClosed || candidate.hasError) {
        await candidate.close();
        continue;
      }
      loop = candidate;
      break;
    }
    loop ??= await UringLoop.open(entries: entries, spin: spin);

    if (_closed) {
      await loop.close();
      throw StateError('UringLoopPool is closed');
    }

    _active++;
    return UringLoopLease._(this, loop);
  }

  Future<void> _release(UringLoopLease lease) async {
    _active--;
    final loop = lease.loop;
    try {
      if (_closed || loop.isClosed || loop.hasError) {
        await loop.close();
      } else {
        _idle.add(loop);
      }
    } finally {
      _maybeCompleteClose();
    }
  }

  /// Stops accepting leases and closes all loops.
  ///
  /// Waiting leases are closed as they are released; the returned future
  /// completes once all active leases have been released.
  Future<void> close() async {
    if (_closed) {
      final completer = _closeCompleter;
      if (completer != null) {
        await completer.future;
      }
      return;
    }

    _closed = true;
    final completer = _closeCompleter = Completer<void>();
    final idle = List<UringLoop>.of(_idle);
    _idle.clear();
    for (final loop in idle) {
      await loop.close();
    }
    _maybeCompleteClose();
    await completer.future;
  }

  void _maybeCompleteClose() {
    if (!_closed || _active > 0) return;
    final completer = _closeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}
