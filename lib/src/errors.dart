import 'ffi/libc.dart';

/// An error reported by an io_uring syscall or by a completion.
final class IoUringException implements Exception {
  IoUringException(this.operation, this.errno, [this.detail]);

  /// Builds an exception from a negative CQE result (`-errno`).
  factory IoUringException.fromCompletion(int result, {String? operation}) {
    return IoUringException(
      operation ?? 'io_uring operation',
      -result,
      'completion result $result',
    );
  }

  final String operation;
  final int errno;
  final String? detail;

  String get message {
    var text = errnoName(errno);
    try {
      text = Libc.instance.strerror(errno);
    } on Object {
      // Keep the symbolic name if libc is unavailable.
    }
    final suffix = detail == null ? '' : ' [$detail]';
    return '$operation failed: $text (errno $errno)$suffix';
  }

  @override
  String toString() => 'IoUringException: $message';
}

/// Common errno names (Linux generic numbering).
String errnoName(int code) => switch (code) {
  1 => 'EPERM',
  2 => 'ENOENT',
  3 => 'ESRCH',
  4 => 'EINTR',
  5 => 'EIO',
  6 => 'ENXIO',
  7 => 'E2BIG',
  8 => 'ENOEXEC',
  9 => 'EBADF',
  10 => 'ECHILD',
  11 => 'EAGAIN',
  12 => 'ENOMEM',
  13 => 'EACCES',
  14 => 'EFAULT',
  15 => 'ENOTBLK',
  16 => 'EBUSY',
  17 => 'EEXIST',
  18 => 'EXDEV',
  19 => 'ENODEV',
  20 => 'ENOTDIR',
  21 => 'EISDIR',
  22 => 'EINVAL',
  23 => 'ENFILE',
  24 => 'EMFILE',
  25 => 'ENOTTY',
  26 => 'ETXTBSY',
  27 => 'EFBIG',
  28 => 'ENOSPC',
  29 => 'ESPIPE',
  30 => 'EROFS',
  31 => 'EMLINK',
  32 => 'EPIPE',
  33 => 'EDOM',
  34 => 'ERANGE',
  38 => 'ENOSYS',
  40 => 'ELOOP',
  62 => 'ETIME',
  75 => 'EOVERFLOW',
  88 => 'ENOTSOCK',
  89 => 'EDESTADDRREQ',
  95 => 'EOPNOTSUPP',
  98 => 'EADDRINUSE',
  99 => 'EADDRNOTAVAIL',
  103 => 'ECONNABORTED',
  104 => 'ECONNRESET',
  105 => 'ENOBUFS',
  110 => 'ETIMEDOUT',
  111 => 'ECONNREFUSED',
  125 => 'ECANCELED',
  _ => 'errno $code',
};
