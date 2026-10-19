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

  static int get errno => Libc.instance.errno;
}
