import 'dart:ffi';

import '../ffi/constants.dart';

/// `struct io_uring_cqe` (16 bytes).
final class IoUringCqe extends Struct {
  @Uint64()
  external int userData;
  @Int32()
  external int res;
  @Uint32()
  external int flags;
}

/// Immutable copy of a completion, safe to keep after the CQ slot is reused.
final class IoUringCompletion {
  const IoUringCompletion({
    required this.userData,
    required this.result,
    required this.flags,
  });

  final int userData;

  /// Kernel result: `>= 0` on success (bytes / fd / 0), `< 0` is `-errno`.
  final int result;

  final int flags;

  bool get isError => result < 0;

  /// Positive errno when [isError], otherwise 0.
  int get errno => result < 0 ? -result : 0;

  bool get hasBuffer => (flags & IoUringCqeFlags.buffer) != 0;

  bool get more => (flags & IoUringCqeFlags.more) != 0;

  bool get sockNonEmpty => (flags & IoUringCqeFlags.sockNonEmpty) != 0;

  bool get isNotification => (flags & IoUringCqeFlags.notif) != 0;

  /// Buffer id selected by the kernel when [hasBuffer] is true.
  int get bufferId => (flags >> 16) & 0xFFFF;

  @override
  String toString() =>
      'IoUringCompletion(userData: $userData, result: $result, '
      'flags: 0x${flags.toRadixString(16)})';
}
