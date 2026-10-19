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
  });

  final int fd;
  final IoUringAsyncLayout layout;
  final SendPort completions;
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
    if (shutdown) {
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

  IoUringAsyncLayout get layout => _layout;

  bool get isClosed => _closed;

  int get pendingCount => _pending.length;

  /// Creates a ring and starts its reaper isolate.
  static Future<UringLoop> open({int entries = 256}) async {
    final ring = IoUring(entries: entries);
    try {
      return await fromRing(ring);
    } on Object {
      ring.close();
      rethrow;
    }
  }

  /// Starts a reaper for an existing ring.
  ///
  /// The ring must not have in-flight operations that the caller will reap
  /// manually; from this point on its CQ is owned by the loop.
  static Future<UringLoop> fromRing(IoUring ring) async {
    final layout = ring.asyncLayout;
    final port = RawReceivePort();
    final loop = UringLoop._(ring, layout, port);
    port.handler = loop._handleMessage;
    try {
      loop._reaper = await Isolate.spawn(
        _reaperMain,
        _ReaperConfig(fd: ring.fd, layout: layout, completions: port.sendPort),
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
    final completer = Completer<IoUringCompletion>();
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
      final completer = Completer<IoUringCompletion>();
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
    if (message is! List) return;
    final values = message.cast<int>();
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
