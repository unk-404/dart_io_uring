import 'dart:ffi';

import '../errors.dart';
import '../ffi/constants.dart';
import '../ffi/libc.dart';
import 'params.dart';

/// The three mappings that back a ring: SQ ring, CQ ring and the SQE array.
final class RingMemory {
  RingMemory._({
    required this.sqRing,
    required this.cqRing,
    required this.sqes,
    required this.sqRingSize,
    required this.cqRingSize,
    required this.sqesSize,
    required this.singleMmap,
  });

  factory RingMemory.map({
    required int fd,
    required IoUringParameters parameters,
  }) {
    final libc = Libc.instance;
    final sqRingSize = parameters.sqOff.array + parameters.sqEntries * 4;
    final cqRingSize = parameters.cqOff.cqes + parameters.cqEntries * 16;
    final singleMmap = parameters.hasSingleMmap;
    final sqesSize = parameters.sqEntries * 64;

    final ringSize = singleMmap
        ? (sqRingSize > cqRingSize ? sqRingSize : cqRingSize)
        : 0;

    if (singleMmap) {
      final sqRing = _map(libc, ringSize, fd, IoUringMmapOffset.sqRing);
      try {
        final sqes = _map(libc, sqesSize, fd, IoUringMmapOffset.sqes);
        return RingMemory._(
          sqRing: sqRing,
          cqRing: sqRing,
          sqes: sqes,
          sqRingSize: ringSize,
          cqRingSize: ringSize,
          sqesSize: sqesSize,
          singleMmap: true,
        );
      } on Object {
        libc.munmap(sqRing, ringSize);
        rethrow;
      }
    }

    final sqRing = _map(libc, sqRingSize, fd, IoUringMmapOffset.sqRing);
    late final Pointer<Uint8> cqRing;
    try {
      cqRing = _map(libc, cqRingSize, fd, IoUringMmapOffset.cqRing);
    } on Object {
      libc.munmap(sqRing, sqRingSize);
      rethrow;
    }
    try {
      final sqes = _map(libc, sqesSize, fd, IoUringMmapOffset.sqes);
      return RingMemory._(
        sqRing: sqRing,
        cqRing: cqRing,
        sqes: sqes,
        sqRingSize: sqRingSize,
        cqRingSize: cqRingSize,
        sqesSize: sqesSize,
        singleMmap: false,
      );
    } on Object {
      libc.munmap(sqRing, sqRingSize);
      libc.munmap(cqRing, cqRingSize);
      rethrow;
    }
  }

  final Pointer<Uint8> sqRing;
  final Pointer<Uint8> cqRing;
  final Pointer<Uint8> sqes;
  final int sqRingSize;
  final int cqRingSize;
  final int sqesSize;
  final bool singleMmap;

  bool _unmapped = false;

  static Pointer<Uint8> _map(Libc libc, int size, int fd, int offset) {
    final pointer = libc.mmap(size, fd: fd, offset: offset);
    // MAP_FAILED is (void *) -1.
    if (pointer.address == -1) {
      throw IoUringException('mmap', libc.errno);
    }
    return pointer;
  }

  void unmap() {
    if (_unmapped) return;
    _unmapped = true;
    final libc = Libc.instance;
    libc.munmap(sqes, sqesSize);
    if (singleMmap) {
      libc.munmap(sqRing, sqRingSize);
    } else {
      libc.munmap(sqRing, sqRingSize);
      libc.munmap(cqRing, cqRingSize);
    }
  }
}
