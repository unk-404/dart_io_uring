import 'dart:ffi';

import '../buffer.dart';
import '../ffi/constants.dart';
import '../os/posix.dart';
import '../ring/sqe.dart';

/// A typed encoder for one SQE.
///
/// Implementations only fill the fields they need; the SQE slot has already
/// been zeroed and its `opcode`/`userData` set by the ring.
abstract interface class UringOp {
  int get opcode;

  void prepare(Pointer<IoUringSqe> sqe);
}

void _setFd(IoUringSqe sqe, int fd, bool fixed) {
  sqe.fd = fd;
  if (fixed) {
    sqe.flags |= IoUringSqeFlags.fixedFile;
  }
}

/// `IORING_OP_NOP`: does nothing, useful for ring round-trip tests.
final class NopOp implements UringOp {
  const NopOp();

  @override
  int get opcode => IoUringOpcode.nop;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref.fd = -1;
  }
}

/// `IORING_OP_READ`: positional read into a native buffer.
final class ReadOp implements UringOp {
  const ReadOp({
    required this.fd,
    required this.buffer,
    required this.length,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int offset;
  final int rwFlags;

  /// Whether [fd] is an index into the registered-file table.
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.read;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..off = offset
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_WRITE`: positional write from a native buffer.
final class WriteOp implements UringOp {
  const WriteOp({
    required this.fd,
    required this.buffer,
    required this.length,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int offset;
  final int rwFlags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.write;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..off = offset
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_FSYNC`.
final class FsyncOp implements UringOp {
  const FsyncOp({required this.fd, this.flags = 0, this.fixedFile = false});

  final int fd;
  final int flags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.fsync;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry.opFlags = flags;
  }
}

/// `IORING_OP_READ_FIXED`: read into a registered buffer.
final class ReadFixedOp implements UringOp {
  const ReadFixedOp({
    required this.fd,
    required this.buffer,
    required this.length,
    required this.bufIndex,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int bufIndex;
  final int offset;
  final int rwFlags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.readFixed;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..off = offset
      ..bufIndex = bufIndex
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_WRITE_FIXED`: write from a registered buffer.
final class WriteFixedOp implements UringOp {
  const WriteFixedOp({
    required this.fd,
    required this.buffer,
    required this.length,
    required this.bufIndex,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int bufIndex;
  final int offset;
  final int rwFlags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.writeFixed;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..off = offset
      ..bufIndex = bufIndex
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_OPENAT`.
///
/// [path] must stay alive until the completion is reaped.
final class OpenAtOp implements UringOp {
  const OpenAtOp({
    required this.path,
    this.dirFd = PosixConstants.atFdCwd,
    this.flags = PosixConstants.oRdonly,
    this.mode = 0,
    this.fixedDirFd = false,
  });

  final UringPath path;
  final int dirFd;
  final int flags;
  final int mode;
  final bool fixedDirFd;

  @override
  int get opcode => IoUringOpcode.openat;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, dirFd, fixedDirFd);
    entry
      ..addr = path.pointer.address
      ..len = mode
      ..opFlags = flags;
  }
}

/// `IORING_OP_CLOSE`.
final class CloseOp implements UringOp {
  const CloseOp({required this.fd, this.fixedFile = false});

  final int fd;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.close;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    if (fixedFile) {
      entry
        ..fd = 0
        ..spliceFdIn = fd + 1;
    } else {
      entry.fd = fd;
    }
  }
}

/// `IORING_OP_STATX`.
///
/// [statxBuffer] must point to at least 256 bytes and stay alive until the
/// completion is reaped.
final class StatxOp implements UringOp {
  const StatxOp({
    required this.path,
    required this.statxBuffer,
    this.dirFd = PosixConstants.atFdCwd,
    this.flags = 0,
    this.mask = 0x7ff, // STATX_BASIC_STATS
    this.fixedDirFd = false,
  });

  final UringPath path;
  final Pointer<Uint8> statxBuffer;
  final int dirFd;
  final int flags;
  final int mask;
  final bool fixedDirFd;

  @override
  int get opcode => IoUringOpcode.statx;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, dirFd, fixedDirFd);
    entry
      ..addr = path.pointer.address
      ..off = statxBuffer.address
      ..len = mask
      ..opFlags = flags;
  }
}

/// `IORING_OP_READV`.
///
/// [iovecs] must stay alive until the completion is reaped.
final class ReadvOp implements UringOp {
  const ReadvOp({
    required this.fd,
    required this.iovecs,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final UringIoVecList iovecs;
  final int offset;
  final int rwFlags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.readv;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = iovecs.pointer.address
      ..len = iovecs.count
      ..off = offset
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_WRITEV`.
final class WritevOp implements UringOp {
  const WritevOp({
    required this.fd,
    required this.iovecs,
    this.offset = 0,
    this.rwFlags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final UringIoVecList iovecs;
  final int offset;
  final int rwFlags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.writev;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = iovecs.pointer.address
      ..len = iovecs.count
      ..off = offset
      ..opFlags = rwFlags;
  }
}

/// `IORING_OP_FTRUNCATE`.
final class FtruncateOp implements UringOp {
  const FtruncateOp({
    required this.fd,
    required this.length,
    this.fixedFile = false,
  });

  final int fd;
  final int length;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.ftruncate;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry.off = length;
  }
}

/// `IORING_OP_FALLOCATE`.
final class FallocateOp implements UringOp {
  const FallocateOp({
    required this.fd,
    required this.length,
    this.offset = 0,
    this.mode = 0,
    this.fixedFile = false,
  });

  final int fd;
  final int length;
  final int offset;
  final int mode;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.fallocate;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = length
      ..off = offset
      ..len = mode;
  }
}
