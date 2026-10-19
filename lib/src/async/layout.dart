/// Immutable description of the CQ ring layout, shared with the reaper isolate.
final class IoUringAsyncLayout {
  const IoUringAsyncLayout({
    required this.fd,
    required this.cqRingAddress,
    required this.cqHeadOffset,
    required this.cqTailOffset,
    required this.cqMask,
    required this.cqesOffset,
    required this.cqeSize,
  });

  final int fd;
  final int cqRingAddress;
  final int cqHeadOffset;
  final int cqTailOffset;
  final int cqMask;
  final int cqesOffset;
  final int cqeSize;

  @override
  String toString() =>
      'IoUringAsyncLayout(fd: $fd, cqMask: $cqMask, cqeSize: $cqeSize)';
}
