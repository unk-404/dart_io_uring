import 'dart:convert';
import 'dart:ffi';

import '../errors.dart';
import '../ffi/constants.dart';
import '../ffi/libc.dart';

/// A NUL-terminated UTF-8 path in native memory.
///
/// Needed by io_uring path operations (e.g. `OPENAT`), whose SQE only carries a
/// pointer. Keep it alive until the completion arrives.
final class UringPath {
  UringPath._(this.pointer, this.length);

  factory UringPath(String path) {
    final encoded = utf8.encode(path);
    final native = Libc.instance.malloc(encoded.length + 1);
    if (native.address == 0) {
      throw IoUringException('malloc', 12); // ENOMEM
    }
    final view = native.asTypedList(encoded.length + 1);
    view.setRange(0, encoded.length, encoded);
    view[encoded.length] = 0;
    return UringPath._(native, encoded.length);
  }

  final Pointer<Uint8> pointer;

  /// Length in bytes, excluding the NUL terminator.
  final int length;

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.free(pointer);
  }
}

/// A native IPv4 `sockaddr_in` (16 bytes).
///
/// Only the subset needed by loopback/TCP examples and tests is exposed; use
/// raw pointers with [IoUring]'s network ops for other address families.
final class UringSockAddr {
  UringSockAddr._(this.pointer, this.length);

  factory UringSockAddr.inet({
    required int port,
    List<int> address = const [127, 0, 0, 1],
  }) {
    if (port < 0 || port > 0xFFFF) {
      throw ArgumentError.value(port, 'port', 'must be in 0..65535');
    }
    if (address.length != 4) {
      throw ArgumentError.value(address, 'address', 'must contain 4 octets');
    }
    final pointer = Libc.instance.calloc(1, 16);
    if (pointer.address == 0) {
      throw IoUringException('calloc', 12);
    }
    final bytes = pointer.asTypedList(16);
    // sa_family_t is host byte order; port and address are network byte order.
    bytes[0] = SocketConstants.afInet & 0xFF;
    bytes[1] = (SocketConstants.afInet >> 8) & 0xFF;
    bytes[2] = (port >> 8) & 0xFF;
    bytes[3] = port & 0xFF;
    for (var i = 0; i < 4; i++) {
      bytes[4 + i] = address[i] & 0xFF;
    }
    return UringSockAddr._(pointer, 16);
  }

  final Pointer<Uint8> pointer;
  final int length;

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.free(pointer);
  }
}

/// A pipe created by `pipe2(2)`.
final class UringPipe {
  const UringPipe(this.readFd, this.writeFd);

  final int readFd;
  final int writeFd;

  void close() {
    try {
      Posix.close(readFd);
    } on Object {
      // Best-effort cleanup.
    }
    try {
      Posix.close(writeFd);
    } on Object {
      // Best-effort cleanup.
    }
  }
}

/// Minimal raw-fd helpers.
///
/// `dart:io` does not expose file descriptors, but io_uring operations need
/// them, so the package opens/closes fds itself through libc.
abstract final class Posix {
  static int open(
    String path, {
    int flags = PosixConstants.oRdonly,
    int mode = 0,
  }) {
    final nativePath = UringPath(path);
    try {
      final fd = Libc.instance.openat(
        PosixConstants.atFdCwd,
        nativePath.pointer,
        flags,
        mode,
      );
      if (fd < 0) {
        throw IoUringException('openat', Libc.instance.errno);
      }
      return fd;
    } finally {
      nativePath.dispose();
    }
  }

  static void close(int fd) {
    final result = Libc.instance.close(fd);
    if (result != 0) {
      throw IoUringException('close', Libc.instance.errno);
    }
  }

  static int eventfd({int initval = 0, int flags = 0}) {
    final fd = Libc.instance.eventfd(initval, flags);
    if (fd < 0) {
      throw IoUringException('eventfd', Libc.instance.errno);
    }
    return fd;
  }

  static int read(int fd, Pointer<Uint8> buffer, int count) {
    final result = Libc.instance.read(fd, buffer, count);
    if (result < 0) {
      throw IoUringException('read', Libc.instance.errno);
    }
    return result;
  }

  static int write(int fd, Pointer<Uint8> buffer, int count) {
    final result = Libc.instance.write(fd, buffer, count);
    if (result < 0) {
      throw IoUringException('write', Libc.instance.errno);
    }
    return result;
  }

  static UringPipe pipe2({int flags = 0}) {
    final libc = Libc.instance;
    final pointer = libc.calloc(1, 8);
    if (pointer.address == 0) {
      throw StateError('Failed to allocate pipe fds');
    }
    try {
      final result = libc.pipe2(pointer.cast<Int32>(), flags);
      if (result != 0) {
        throw IoUringException('pipe2', libc.errno);
      }
      final fds = pointer.cast<Int32>();
      return UringPipe(fds.value, (fds + 1).value);
    } finally {
      libc.free(pointer);
    }
  }

  /// Reads the bound port of an IPv4 socket.
  static int localPort(int fd) {
    final libc = Libc.instance;
    final address = libc.calloc(1, 16);
    final lengthPointer = libc.calloc(1, 4);
    if (address.address == 0 || lengthPointer.address == 0) {
      if (address.address != 0) libc.free(address);
      if (lengthPointer.address != 0) libc.free(lengthPointer);
      throw StateError('Failed to allocate getsockname buffers');
    }
    try {
      final length = lengthPointer.cast<Uint32>();
      length.value = 16;
      final result = libc.getsockname(fd, address, length);
      if (result != 0) {
        throw IoUringException('getsockname', libc.errno);
      }
      final bytes = address.asTypedList(16);
      return (bytes[2] << 8) | bytes[3];
    } finally {
      libc.free(address);
      libc.free(lengthPointer);
    }
  }

  static int get errno => Libc.instance.errno;
}
