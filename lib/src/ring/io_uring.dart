import 'dart:ffi';

import '../buffer.dart';
import '../errors.dart';
import '../ffi/constants.dart';
import '../ffi/libc.dart';
import '../ffi/memory_barrier.dart';
import '../ops/op.dart';
import '../register/probe.dart';
import 'cqe.dart';
import 'params.dart';
import 'ring_memory.dart';
import 'sqe.dart';

/// A synchronous io_uring instance.
///
/// This is the low-level core: it owns one ring fd and its SQ/CQ mappings and
/// exposes submission/completion primitives. It does not create a thread or an
/// event loop; callers use it from a single isolate (or from the owner isolate
/// of the async layer).
final class IoUring {
  factory IoUring({
    int entries = 256,
    int flags = 0,
    int cqEntries = 0,
    int sqThreadCpu = 0,
    int sqThreadIdle = 0,
  }) {
    if (entries <= 0) {
      throw ArgumentError.value(entries, 'entries', 'must be positive');
    }
    if (cqEntries < 0) {
      throw ArgumentError.value(cqEntries, 'cqEntries', 'must not be negative');
    }

    const unsupportedFlags =
        IoUringSetupFlags.sqe128 |
        IoUringSetupFlags.cqe32 |
        IoUringSetupFlags.noMmap |
        IoUringSetupFlags.noSqarray |
        IoUringSetupFlags.cqeMixed |
        IoUringSetupFlags.sqeMixed;
    if ((flags & unsupportedFlags) != 0) {
      throw UnsupportedError(
        'SQE128/CQE32/NO_MMAP/NO_SQARRAY/mixed rings are not supported yet',
      );
    }

    final barrier = MemoryBarrier.create();
    var effectiveFlags = flags;
    if (cqEntries > 0) {
      effectiveFlags |= IoUringSetupFlags.cqsize;
    }

    final libc = Libc.instance;
    final paramsPointer = libc.calloc(1, sizeOf<IoUringParams>());
    if (paramsPointer.address == 0) {
      throw StateError('Failed to allocate io_uring_params');
    }

    var fd = -1;
    late IoUringParameters parameters;
    try {
      final params = paramsPointer.cast<IoUringParams>().ref;
      params
        ..flags = effectiveFlags
        ..cqEntries = cqEntries
        ..sqThreadCpu = sqThreadCpu
        ..sqThreadIdle = sqThreadIdle;

      fd = libc.syscall6(
        IoUringSyscall.setup,
        entries,
        paramsPointer.address,
        0,
        0,
        0,
        0,
      );
      if (fd < 0) {
        throw IoUringException('io_uring_setup', libc.errno);
      }
      parameters = IoUringParameters.fromStruct(params);
    } finally {
      libc.free(paramsPointer);
    }

    try {
      final memory = RingMemory.map(fd: fd, parameters: parameters);
      return IoUring._(fd, parameters, memory, barrier);
    } on Object {
      libc.close(fd);
      rethrow;
    }
  }

  IoUring._(this.fd, this.parameters, this._memory, this._barrier) {
    _sqeSize = sizeOf<IoUringSqe>();
    _cqeSize = sizeOf<IoUringCqe>();

    _sqes = _memory.sqes;
    _cqes = _memory.cqRing + parameters.cqOff.cqes;

    _sqHeadPtr = _u32(_memory.sqRing, parameters.sqOff.head);
    _sqTailPtr = _u32(_memory.sqRing, parameters.sqOff.tail);
    _sqMaskPtr = _u32(_memory.sqRing, parameters.sqOff.ringMask);
    _sqEntriesPtr = _u32(_memory.sqRing, parameters.sqOff.ringEntries);
    _sqFlagsPtr = _u32(_memory.sqRing, parameters.sqOff.flags);
    _sqDroppedPtr = _u32(_memory.sqRing, parameters.sqOff.dropped);
    _sqArray = _u32(_memory.sqRing, parameters.sqOff.array);

    _cqHeadPtr = _u32(_memory.cqRing, parameters.cqOff.head);
    _cqTailPtr = _u32(_memory.cqRing, parameters.cqOff.tail);
    _cqMaskPtr = _u32(_memory.cqRing, parameters.cqOff.ringMask);
    _cqEntriesPtr = _u32(_memory.cqRing, parameters.cqOff.ringEntries);

    _sqMask = _sqMaskPtr.value;
    _sqEntries = _sqEntriesPtr.value;
    _cqMask = _cqMaskPtr.value;
    _cqEntries = _cqEntriesPtr.value;

    _sqeHead = _sqHeadPtr.value;
    _sqeTail = _sqTailPtr.value;
    _sqTail = _sqeTail;
    _cqHead = _cqHeadPtr.value;

    // The kernel's SQ array is a fixed identity mapping; only the SQE array is
    // mutated. Initializing it once means submissions never touch the array.
    for (var i = 0; i < _sqEntries; i++) {
      (_sqArray + i).value = i;
    }
  }

  final int fd;
  final IoUringParameters parameters;
  final RingMemory _memory;
  final MemoryBarrier _barrier;

  late final int _sqeSize;
  late final int _cqeSize;

  late final Pointer<Uint8> _sqes;
  late final Pointer<Uint8> _cqes;

  late final Pointer<Uint32> _sqHeadPtr;
  late final Pointer<Uint32> _sqTailPtr;
  late final Pointer<Uint32> _sqMaskPtr;
  late final Pointer<Uint32> _sqEntriesPtr;
  late final Pointer<Uint32> _sqFlagsPtr;
  late final Pointer<Uint32> _sqDroppedPtr;
  late final Pointer<Uint32> _sqArray;

  late final Pointer<Uint32> _cqHeadPtr;
  late final Pointer<Uint32> _cqTailPtr;
  late final Pointer<Uint32> _cqMaskPtr;
  late final Pointer<Uint32> _cqEntriesPtr;

  late final int _sqMask;
  late final int _sqEntries;
  late final int _cqMask;
  late final int _cqEntries;

  /// SQE slot the kernel has consumed up to (from `sq.head`).
  int _sqeHead = 0;

  /// Next SQE slot we may fill (may be ahead of the published tail).
  int _sqeTail = 0;

  /// Tail already published to the kernel.
  int _sqTail = 0;

  /// CQ entries consumed by us.
  int _cqHead = 0;

  bool _closed = false;

  int get sqCapacity => _sqEntries;

  int get cqCapacity => _cqEntries;

  /// Number of slots occupied (submitted or pending) but not yet consumed by
  /// the kernel.
  int get sqPending => (_sqeTail - _sqeHead) & 0xFFFFFFFF;

  /// Number of filled SQE slots that have not been submitted yet.
  int get sqReady => (_sqeTail - _sqTail) & 0xFFFFFFFF;

  /// Free SQ slots, refreshing the kernel head first.
  int get sqFree {
    _refreshSqHead();
    return _sqEntries - ((_sqeTail - _sqeHead) & 0xFFFFFFFF);
  }

  /// Completions currently available.
  int get cqReady => (_readCqTail() - _cqHead) & 0xFFFFFFFF;

  int get sqDropped => _sqDroppedPtr.value;

  bool get cqOverflow => (_sqFlagsPtr.value & IoUringSqFlags.cqOverflow) != 0;

  bool get sqNeedWakeup => (_sqFlagsPtr.value & IoUringSqFlags.needWakeup) != 0;

  bool get isClosed => _closed;

  /// Reserves and zeroes the next SQE slot, or returns `null` when the ring is
  /// full. The caller must eventually call [submit].
  Pointer<IoUringSqe>? nextSqe() {
    _ensureOpen();
    if (((_sqeTail - _sqeHead) & 0xFFFFFFFF) >= _sqEntries) {
      _refreshSqHead();
      if (((_sqeTail - _sqeHead) & 0xFFFFFFFF) >= _sqEntries) {
        return null;
      }
    }

    final slot = _sqeTail & _sqMask;
    final pointer = (_sqes + (slot * _sqeSize)).cast<IoUringSqe>();
    pointer.cast<Uint8>().asTypedList(_sqeSize).fillRange(0, _sqeSize, 0);
    _sqeTail = (_sqeTail + 1) & 0xFFFFFFFF;
    return pointer;
  }

  /// Encodes [op] into a fresh SQE.
  ///
  /// [sqeFlags] are `IOSQE_*` flags (e.g. `IoUringSqeFlags.ioLink`).
  void push(UringOp op, {int userData = 0, int sqeFlags = 0}) {
    final pointer = nextSqe();
    if (pointer == null) {
      throw StateError('Submission queue is full');
    }
    pointer.ref
      ..userData = userData
      ..opcode = op.opcode
      ..flags = sqeFlags;
    op.prepare(pointer);
  }

  /// Publishes all filled SQEs and calls `io_uring_enter` without waiting.
  int submit() {
    _ensureOpen();
    _refreshSqHead();
    final toSubmit = (_sqeTail - _sqeHead) & 0xFFFFFFFF;
    if (toSubmit == 0) return 0;
    if (_sqTail != _sqeTail) {
      _publishSqTail();
    }
    final submitted = _enter(toSubmit, 0, 0);
    _refreshSqHead();
    return submitted;
  }

  /// Publishes SQEs and waits for [waitFor] completions (0 = don't wait).
  int submitAndWait(int waitFor) {
    _ensureOpen();
    if (waitFor < 0) {
      throw ArgumentError.value(waitFor, 'waitFor', 'must not be negative');
    }
    _refreshSqHead();
    final toSubmit = (_sqeTail - _sqeHead) & 0xFFFFFFFF;
    if (_sqTail != _sqeTail) {
      _publishSqTail();
    }
    _publishCqHead();
    final flags = waitFor > 0 ? IoUringEnterFlags.getEvents : 0;
    final submitted = _enter(toSubmit, waitFor, flags);
    _refreshSqHead();
    return submitted;
  }

  /// Blocks until at least one completion is available and returns it.
  IoUringCompletion waitCqe() {
    _ensureOpen();
    _publishCqHead();
    while (true) {
      final tail = _readCqTail();
      if (_cqHead != tail) {
        return _popCqe();
      }
      _enter(0, 1, IoUringEnterFlags.getEvents);
    }
  }

  /// Returns the next completion without blocking, or `null`.
  IoUringCompletion? nextCqe() {
    _ensureOpen();
    final tail = _readCqTail();
    if (_cqHead == tail) return null;
    return _popCqe();
  }

  /// Queries which operations the running kernel supports.
  IoUringProbeResult probe({int maxOps = 256}) {
    _ensureOpen();
    if (maxOps <= 0 || maxOps > 256) {
      throw ArgumentError.value(maxOps, 'maxOps', 'must be in 1..256');
    }
    final libc = Libc.instance;
    final size = sizeOf<IoUringProbe>() + maxOps * sizeOf<IoUringProbeOp>();
    final pointer = libc.calloc(1, size);
    if (pointer.address == 0) {
      throw StateError('Failed to allocate io_uring_probe');
    }
    try {
      _register(IoUringRegisterOpcode.probe, pointer.address, maxOps);
      final header = pointer.cast<IoUringProbe>().ref;
      final count = header.opsLen;
      final base = (pointer + sizeOf<IoUringProbe>()).cast<IoUringProbeOp>();
      final ops = <int, int>{};
      for (var i = 0; i < count; i++) {
        final op = (base + i).ref;
        ops[op.op] = op.flags;
      }
      return IoUringProbeResult(lastOp: header.lastOp, ops: ops);
    } finally {
      libc.free(pointer);
    }
  }

  /// Registers buffers for `READ_FIXED` / `WRITE_FIXED`.
  ///
  /// The buffers must outlive the registration.
  void registerBuffers(List<UringBuffer> buffers) {
    _ensureOpen();
    if (buffers.isEmpty) {
      throw ArgumentError.value(buffers, 'buffers', 'must not be empty');
    }
    final libc = Libc.instance;
    final array = libc.calloc(buffers.length, 16);
    if (array.address == 0) {
      throw StateError('Failed to allocate iovec array');
    }
    try {
      final words = array.cast<Uint64>();
      for (var i = 0; i < buffers.length; i++) {
        (words + i * 2).value = buffers[i].pointer.address;
        (words + i * 2 + 1).value = buffers[i].length;
      }
      _register(IoUringRegisterOpcode.buffers, array.address, buffers.length);
    } finally {
      libc.free(array);
    }
  }

  void unregisterBuffers() {
    _ensureOpen();
    _register(IoUringRegisterOpcode.unregisterBuffers, 0, 0);
  }

  /// Registers file descriptors for `IOSQE_FIXED_FILE` operations.
  void registerFiles(List<int> fds) {
    _ensureOpen();
    if (fds.isEmpty) {
      throw ArgumentError.value(fds, 'fds', 'must not be empty');
    }
    final libc = Libc.instance;
    final array = libc.calloc(fds.length, 4);
    if (array.address == 0) {
      throw StateError('Failed to allocate fd array');
    }
    try {
      final values = array.cast<Int32>();
      for (var i = 0; i < fds.length; i++) {
        (values + i).value = fds[i];
      }
      _register(IoUringRegisterOpcode.files, array.address, fds.length);
    } finally {
      libc.free(array);
    }
  }

  void unregisterFiles() {
    _ensureOpen();
    _register(IoUringRegisterOpcode.unregisterFiles, 0, 0);
  }

  /// Registers an eventfd that the kernel signals when CQEs are posted.
  void registerEventfd(int eventfd) {
    _ensureOpen();
    final libc = Libc.instance;
    final pointer = libc.calloc(1, 4);
    if (pointer.address == 0) {
      throw StateError('Failed to allocate eventfd argument');
    }
    try {
      pointer.cast<Int32>().value = eventfd;
      _register(IoUringRegisterOpcode.eventfd, pointer.address, 1);
    } finally {
      libc.free(pointer);
    }
  }

  void unregisterEventfd() {
    _ensureOpen();
    _register(IoUringRegisterOpcode.unregisterEventfd, 0, 0);
  }

  int _register(int opcode, int argument, int nrArgs) {
    final result = Libc.instance.syscall6(
      IoUringSyscall.register,
      fd,
      opcode,
      argument,
      nrArgs,
      0,
      0,
    );
    if (result < 0) {
      throw IoUringException('io_uring_register($opcode)', Libc.instance.errno);
    }
    return result;
  }

  /// Releases the ring fd and unmaps all ring memory. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _memory.unmap();
    Libc.instance.close(fd);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IoUring is closed');
    }
  }

  @override
  String toString() =>
      'IoUring(fd: $fd, sqEntries: $_sqEntries, cqEntries: $_cqEntries)';

  int _enter(int toSubmit, int minComplete, int flags) {
    while (true) {
      final result = Libc.instance.syscall6(
        IoUringSyscall.enter,
        fd,
        toSubmit,
        minComplete,
        flags,
        0,
        0,
      );
      if (result >= 0) return result;
      final errno = Libc.instance.errno;
      if (errno == 4) {
        // EINTR
        continue;
      }
      throw IoUringException('io_uring_enter', errno);
    }
  }

  void _publishSqTail() {
    _barrier.release();
    _sqTailPtr.value = _sqeTail;
    _sqTail = _sqeTail;
  }

  void _refreshSqHead() {
    final head = _sqHeadPtr.value;
    _barrier.acquire();
    _sqeHead = head;
  }

  int _readCqTail() {
    final tail = _cqTailPtr.value;
    _barrier.acquire();
    return tail;
  }

  void _publishCqHead() {
    _barrier.release();
    _cqHeadPtr.value = _cqHead;
  }

  IoUringCompletion _popCqe() {
    final index = _cqHead & _cqMask;
    final pointer = (_cqes + (index * _cqeSize)).cast<IoUringCqe>();
    final cqe = pointer.ref;
    final completion = IoUringCompletion(
      userData: cqe.userData,
      result: cqe.res,
      flags: cqe.flags,
    );
    _cqHead = (_cqHead + 1) & 0xFFFFFFFF;
    _publishCqHead();
    return completion;
  }

  static Pointer<Uint32> _u32(Pointer<Uint8> base, int offset) =>
      (base + offset).cast<Uint32>();
}
