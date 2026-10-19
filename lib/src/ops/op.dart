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

/// `IORING_OP_SOCKET`: creates a socket and returns its fd in the CQE.
final class SocketOp implements UringOp {
  const SocketOp({
    this.domain = SocketConstants.afInet,
    this.type = SocketConstants.sockStream,
    this.protocol = 0,
  });

  final int domain;
  final int type;
  final int protocol;

  @override
  int get opcode => IoUringOpcode.socket;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = domain
      ..off = type
      ..len = protocol;
  }
}

/// `IORING_OP_BIND`.
final class BindOp implements UringOp {
  const BindOp({
    required this.fd,
    required this.sockaddr,
    required this.addrlen,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> sockaddr;
  final int addrlen;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.bind;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = sockaddr.address
      ..off = addrlen;
  }
}

/// `IORING_OP_LISTEN`.
final class ListenOp implements UringOp {
  const ListenOp({
    required this.fd,
    this.backlog = 128,
    this.fixedFile = false,
  });

  final int fd;
  final int backlog;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.listen;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry.len = backlog;
  }
}

/// `IORING_OP_ACCEPT`.
final class AcceptOp implements UringOp {
  const AcceptOp({
    required this.fd,
    this.addr,
    this.addrLen,
    this.flags = 0,
    this.fixedFile = false,
  });

  final int fd;

  /// Optional `struct sockaddr` output buffer.
  final Pointer<Uint8>? addr;

  /// Optional `socklen_t` input/output buffer.
  final Pointer<Uint32>? addrLen;

  final int flags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.accept;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = addr?.address ?? 0
      ..off = addrLen?.address ?? 0
      ..opFlags = flags;
  }
}

/// `IORING_OP_CONNECT`.
final class ConnectOp implements UringOp {
  const ConnectOp({
    required this.fd,
    required this.sockaddr,
    required this.addrlen,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> sockaddr;
  final int addrlen;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.connect;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = sockaddr.address
      ..off = addrlen;
  }
}

/// `IORING_OP_SEND`.
final class SendOp implements UringOp {
  const SendOp({
    required this.fd,
    required this.buffer,
    required this.length,
    this.flags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int flags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.send;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..opFlags = flags;
  }
}

/// `IORING_OP_RECV`.
final class RecvOp implements UringOp {
  const RecvOp({
    required this.fd,
    required this.buffer,
    required this.length,
    this.flags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final Pointer<Uint8> buffer;
  final int length;
  final int flags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.recv;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..addr = buffer.address
      ..len = length
      ..opFlags = flags;
  }
}

/// `IORING_OP_SHUTDOWN`.
final class ShutdownOp implements UringOp {
  const ShutdownOp({
    required this.fd,
    this.how = SocketConstants.shutRdWr,
    this.fixedFile = false,
  });

  final int fd;
  final int how;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.shutdown;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry.len = how;
  }
}

/// `IORING_OP_SPLICE`.
///
/// [offIn] / [offOut] use `-1` for the current file position.
final class SpliceOp implements UringOp {
  const SpliceOp({
    required this.fdIn,
    this.offIn = -1,
    required this.fdOut,
    this.offOut = -1,
    required this.length,
    this.flags = 0,
    this.fixedIn = false,
    this.fixedOut = false,
  });

  final int fdIn;
  final int offIn;
  final int fdOut;
  final int offOut;
  final int length;
  final int flags;
  final bool fixedIn;
  final bool fixedOut;

  @override
  int get opcode => IoUringOpcode.splice;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fdOut, fixedOut);
    entry
      ..spliceFdIn = fdIn
      ..addr = offIn
      ..off = offOut
      ..len = length
      ..opFlags = flags | (fixedIn ? SpliceFlags.fdInFixed : 0);
  }
}

/// `IORING_OP_TEE`.
final class TeeOp implements UringOp {
  const TeeOp({
    required this.fdIn,
    required this.fdOut,
    required this.length,
    this.flags = 0,
    this.fixedIn = false,
    this.fixedOut = false,
  });

  final int fdIn;
  final int fdOut;
  final int length;
  final int flags;
  final bool fixedIn;
  final bool fixedOut;

  @override
  int get opcode => IoUringOpcode.tee;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fdOut, fixedOut);
    entry
      ..spliceFdIn = fdIn
      ..len = length
      ..opFlags = flags | (fixedIn ? SpliceFlags.fdInFixed : 0);
  }
}

/// `IORING_OP_POLL_ADD`.
final class PollAddOp implements UringOp {
  const PollAddOp({
    required this.fd,
    required this.events,
    this.multi = false,
    this.fixedFile = false,
  });

  final int fd;
  final int events;
  final bool multi;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.pollAdd;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry.opFlags = events;
    if (multi) {
      entry.len = IoUringMultishotFlags.pollAddMulti;
    }
  }
}

/// `IORING_OP_POLL_REMOVE`.
final class PollRemoveOp implements UringOp {
  const PollRemoveOp({required this.userData});

  final int userData;

  @override
  int get opcode => IoUringOpcode.pollRemove;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = -1
      ..addr = userData;
  }
}

/// `IORING_OP_TIMEOUT`.
///
/// [timespec] must stay alive until the completion arrives.
final class TimeoutOp implements UringOp {
  const TimeoutOp({required this.timespec, this.count = 0, this.flags = 0});

  final UringTimespec timespec;
  final int count;
  final int flags;

  @override
  int get opcode => IoUringOpcode.timeout;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = -1
      ..addr = timespec.pointer.address
      ..len = 1
      ..off = count
      ..opFlags = flags;
  }
}

/// `IORING_OP_TIMEOUT_REMOVE`.
final class TimeoutRemoveOp implements UringOp {
  const TimeoutRemoveOp({required this.userData, this.flags = 0});

  final int userData;
  final int flags;

  @override
  int get opcode => IoUringOpcode.timeoutRemove;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = -1
      ..addr = userData
      ..opFlags = flags;
  }
}

/// `IORING_OP_LINK_TIMEOUT`, used as the last entry of a linked chain.
final class LinkTimeoutOp implements UringOp {
  const LinkTimeoutOp({required this.timespec, this.flags = 0});

  final UringTimespec timespec;
  final int flags;

  @override
  int get opcode => IoUringOpcode.linkTimeout;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = -1
      ..addr = timespec.pointer.address
      ..len = 1
      ..opFlags = flags;
  }
}

/// `IORING_OP_ASYNC_CANCEL` targeting a `user_data` value.
final class AsyncCancelOp implements UringOp {
  const AsyncCancelOp({required this.userData, this.flags = 0});

  final int userData;
  final int flags;

  @override
  int get opcode => IoUringOpcode.asyncCancel;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = -1
      ..addr = userData
      ..opFlags = flags;
  }
}

/// `IORING_OP_PROVIDE_BUFFERS`.
final class ProvideBuffersOp implements UringOp {
  const ProvideBuffersOp({
    required this.buffer,
    required this.length,
    required this.count,
    required this.bufferGroup,
    this.bufferId = 0,
  });

  final Pointer<Uint8> buffer;
  final int length;
  final int count;
  final int bufferGroup;
  final int bufferId;

  @override
  int get opcode => IoUringOpcode.provideBuffers;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = count
      ..addr = buffer.address
      ..len = length
      ..off = bufferId
      ..bufIndex = bufferGroup;
  }
}

/// `IORING_OP_REMOVE_BUFFERS`.
final class RemoveBuffersOp implements UringOp {
  const RemoveBuffersOp({required this.count, required this.bufferGroup});

  final int count;
  final int bufferGroup;

  @override
  int get opcode => IoUringOpcode.removeBuffers;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    sqe.ref
      ..fd = count
      ..bufIndex = bufferGroup;
  }
}

/// Multishot `IORING_OP_RECV` with provided-buffer selection.
final class RecvMultiOp implements UringOp {
  const RecvMultiOp({
    required this.fd,
    required this.bufferGroup,
    this.length = 0,
    this.flags = 0,
    this.fixedFile = false,
  });

  final int fd;
  final int bufferGroup;
  final int length;
  final int flags;
  final bool fixedFile;

  @override
  int get opcode => IoUringOpcode.recv;

  @override
  void prepare(Pointer<IoUringSqe> sqe) {
    final entry = sqe.ref;
    _setFd(entry, fd, fixedFile);
    entry
      ..len = length
      ..opFlags = flags
      ..bufIndex = bufferGroup
      ..ioprio = IoUringMultishotFlags.recvMulti
      ..flags |= IoUringSqeFlags.bufferSelect;
  }
}
