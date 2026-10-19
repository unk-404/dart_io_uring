import 'dart:ffi';

import '../ffi/libc.dart';
import '../ffi/memory_barrier.dart';

/// `struct io_uring_buf_reg` (kernel 6.10+ layout; older kernels read a prefix).
final class UringBufReg extends Struct {
  @Uint64()
  external int ringAddr;
  @Uint32()
  external int ringEntries;
  @Uint16()
  external int bgid;
  @Uint16()
  external int flags;
  @Uint32()
  external int minLeft;
  @Array(5)
  external Array<Uint32> resv;
}

/// `struct io_uring_buf` (16 bytes).
final class UringBuf extends Struct {
  @Uint64()
  external int addr;
  @Uint32()
  external int len;
  @Uint16()
  external int bid;
  @Uint16()
  external int resv;
}

/// A registered provided-buffer ring (`IORING_REGISTER_PBUF_RING`).
///
/// The first 16 bytes are shared by the ring tail (at offset 14) and the first
/// buffer entry; [add] writes entries and publishes the tail.
final class UringBufRing {
  UringBufRing({
    required this.pointer,
    required this.entries,
    required this.bufferGroup,
    required this.barrier,
  }) {
    if (entries <= 0 || (entries & (entries - 1)) != 0) {
      throw ArgumentError.value(entries, 'entries', 'must be a power of two');
    }
  }

  final Pointer<Uint8> pointer;
  final int entries;
  final int bufferGroup;
  final MemoryBarrier barrier;

  int _tail = 0;
  bool _disposed = false;

  int get mask => entries - 1;

  int get tail => _tail;

  /// Adds one buffer and publishes it to the kernel.
  void add({
    required Pointer<Uint8> buffer,
    required int length,
    required int bufferId,
  }) {
    if (_disposed) {
      throw StateError('UringBufRing is disposed');
    }
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    if (bufferId < 0 || bufferId > 0xFFFF) {
      throw ArgumentError.value(bufferId, 'bufferId', 'must be in 0..65535');
    }
    final index = _tail & mask;
    final entry = (pointer + index * 16).cast<UringBuf>().ref;
    entry
      ..addr = buffer.address
      ..len = length
      ..bid = bufferId;
    barrier.release();
    _tail = (_tail + 1) & 0xFFFF;
    (pointer + 14).cast<Uint16>().value = _tail;
  }

  /// Unmaps the ring memory. The caller must unregister the ring first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.munmap(pointer, entries * 16);
  }
}
