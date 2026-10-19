import 'dart:ffi';

import '../ffi/constants.dart';

/// `struct io_sqring_offsets` from the kernel UAPI.
final class IoUringSqOffsets extends Struct {
  @Uint32()
  external int head;
  @Uint32()
  external int tail;
  @Uint32()
  external int ringMask;
  @Uint32()
  external int ringEntries;
  @Uint32()
  external int flags;
  @Uint32()
  external int dropped;
  @Uint32()
  external int array;
  @Uint32()
  external int resv1;
  @Uint64()
  external int resv2;
}

/// `struct io_cqring_offsets` from the kernel UAPI.
final class IoUringCqOffsets extends Struct {
  @Uint32()
  external int head;
  @Uint32()
  external int tail;
  @Uint32()
  external int ringMask;
  @Uint32()
  external int ringEntries;
  @Uint32()
  external int overflow;
  @Uint32()
  external int cqes;
  @Uint32()
  external int flags;
  @Uint32()
  external int resv1;
  @Uint64()
  external int resv2;
}

/// `struct io_uring_params` from the kernel UAPI (120 bytes on 64-bit).
final class IoUringParams extends Struct {
  @Uint32()
  external int sqEntries;
  @Uint32()
  external int cqEntries;
  @Uint32()
  external int flags;
  @Uint32()
  external int sqThreadCpu;
  @Uint32()
  external int sqThreadIdle;
  @Uint32()
  external int features;
  @Uint32()
  external int wqFd;
  @Array(3)
  external Array<Uint32> resv;
  external IoUringSqOffsets sqOff;
  external IoUringCqOffsets cqOff;
}

/// Immutable copy of the SQ offsets, safe to keep after `params` is freed.
final class IoUringSqOffsetsView {
  const IoUringSqOffsetsView({
    required this.head,
    required this.tail,
    required this.ringMask,
    required this.ringEntries,
    required this.flags,
    required this.dropped,
    required this.array,
  });

  final int head;
  final int tail;
  final int ringMask;
  final int ringEntries;
  final int flags;
  final int dropped;
  final int array;
}

/// Immutable copy of the CQ offsets, safe to keep after `params` is freed.
final class IoUringCqOffsetsView {
  const IoUringCqOffsetsView({
    required this.head,
    required this.tail,
    required this.ringMask,
    required this.ringEntries,
    required this.overflow,
    required this.cqes,
    required this.flags,
  });

  final int head;
  final int tail;
  final int ringMask;
  final int ringEntries;
  final int overflow;
  final int cqes;
  final int flags;
}

/// Snapshot of the parameters a ring was created with.
final class IoUringParameters {
  const IoUringParameters({
    required this.sqEntries,
    required this.cqEntries,
    required this.flags,
    required this.features,
    required this.sqOff,
    required this.cqOff,
  });

  factory IoUringParameters.fromStruct(IoUringParams params) {
    return IoUringParameters(
      sqEntries: params.sqEntries,
      cqEntries: params.cqEntries,
      flags: params.flags,
      features: params.features,
      sqOff: IoUringSqOffsetsView(
        head: params.sqOff.head,
        tail: params.sqOff.tail,
        ringMask: params.sqOff.ringMask,
        ringEntries: params.sqOff.ringEntries,
        flags: params.sqOff.flags,
        dropped: params.sqOff.dropped,
        array: params.sqOff.array,
      ),
      cqOff: IoUringCqOffsetsView(
        head: params.cqOff.head,
        tail: params.cqOff.tail,
        ringMask: params.cqOff.ringMask,
        ringEntries: params.cqOff.ringEntries,
        overflow: params.cqOff.overflow,
        cqes: params.cqOff.cqes,
        flags: params.cqOff.flags,
      ),
    );
  }

  final int sqEntries;
  final int cqEntries;
  final int flags;
  final int features;
  final IoUringSqOffsetsView sqOff;
  final IoUringCqOffsetsView cqOff;

  bool get isSetupSqpoll => (flags & IoUringSetupFlags.sqpoll) != 0;
  bool get isSetupIopoll => (flags & IoUringSetupFlags.iopoll) != 0;
  bool get isSetupSingleIssuer => (flags & IoUringSetupFlags.singleIssuer) != 0;

  bool get hasSingleMmap => (features & IoUringFeatures.singleMmap) != 0;
  bool get hasNoDrop => (features & IoUringFeatures.noDrop) != 0;
  bool get hasSubmitStable => (features & IoUringFeatures.submitStable) != 0;
  bool get hasRwCurPos => (features & IoUringFeatures.rwCurPos) != 0;
  bool get hasExtArg => (features & IoUringFeatures.extArg) != 0;
  bool get hasNativeWorkers => (features & IoUringFeatures.nativeWorkers) != 0;
  bool get hasCqeSkip => (features & IoUringFeatures.cqeSkip) != 0;
  bool get hasLinkedFile => (features & IoUringFeatures.linkedFile) != 0;
  bool get hasRegRegRing => (features & IoUringFeatures.regRegRing) != 0;

  @override
  String toString() =>
      'IoUringParameters(sqEntries: $sqEntries, cqEntries: $cqEntries, '
      'flags: 0x${flags.toRadixString(16)}, '
      'features: 0x${features.toRadixString(16)})';
}
