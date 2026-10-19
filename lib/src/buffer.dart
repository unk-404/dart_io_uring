import 'dart:ffi';
import 'dart:typed_data';

import 'errors.dart';
import 'ffi/libc.dart';

/// A native buffer that can be handed to the kernel.
///
/// Dart heap `Uint8List`s are not used directly: the VM does not expose their
/// address and a moving GC could relocate them while the kernel is reading or
/// writing. Instead this class owns `calloc`'d native memory.
final class UringBuffer {
  UringBuffer._(this.pointer, this.length);

  factory UringBuffer.allocate(int length) {
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    final pointer = Libc.instance.calloc(length, 1);
    if (pointer.address == 0) {
      throw IoUringException('calloc', 12); // ENOMEM
    }
    return UringBuffer._(pointer, length);
  }

  /// Wraps an existing native allocation. The caller keeps ownership.
  factory UringBuffer.fromPointer(Pointer<Uint8> pointer, int length) {
    return UringBuffer._(pointer, length);
  }

  final Pointer<Uint8> pointer;
  final int length;

  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// A view over the native memory. Do not use after [dispose].
  Uint8List get bytes => pointer.asTypedList(length);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.free(pointer);
  }
}

/// A native `struct __kernel_timespec` (16 bytes) for timeout operations.
final class UringTimespec {
  UringTimespec({required int seconds, int nanoseconds = 0}) {
    if (seconds < 0) {
      throw ArgumentError.value(seconds, 'seconds', 'must not be negative');
    }
    if (nanoseconds < 0 || nanoseconds > 999999999) {
      throw ArgumentError.value(
        nanoseconds,
        'nanoseconds',
        'must be in 0..999999999',
      );
    }
    final memory = Libc.instance.calloc(1, 16);
    if (memory.address == 0) {
      throw IoUringException('calloc', 12);
    }
    final words = memory.cast<Int64>();
    words.value = seconds;
    (words + 1).value = nanoseconds;
    pointer = memory;
  }

  factory UringTimespec.milliseconds(int milliseconds) {
    return UringTimespec(
      seconds: milliseconds ~/ 1000,
      nanoseconds: (milliseconds % 1000) * 1000000,
    );
  }

  late final Pointer<Uint8> pointer;

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.free(pointer);
  }
}

/// One element of a `readv`/`writev` vector.
final class UringIoVec {
  const UringIoVec({required this.buffer, required this.length});

  final Pointer<Uint8> buffer;
  final int length;
}

/// A native `struct iovec[]` array.
///
/// The array (and the buffers it points at) must stay alive until the
/// completion arrives.
final class UringIoVecList {
  UringIoVecList(List<UringIoVec> vectors) : count = vectors.length {
    if (vectors.isEmpty) {
      throw ArgumentError.value(vectors, 'vectors', 'must not be empty');
    }
    final memory = Libc.instance.calloc(vectors.length, 16);
    if (memory.address == 0) {
      throw IoUringException('calloc', 12);
    }
    final words = memory.cast<Uint64>();
    for (var i = 0; i < vectors.length; i++) {
      (words + i * 2).value = vectors[i].buffer.address;
      (words + i * 2 + 1).value = vectors[i].length;
    }
    _pointer = memory;
  }

  factory UringIoVecList.fromBuffers(List<UringBuffer> buffers) {
    return UringIoVecList([
      for (final buffer in buffers)
        UringIoVec(buffer: buffer.pointer, length: buffer.length),
    ]);
  }

  late final Pointer<Uint8> _pointer;
  final int count;

  bool _disposed = false;

  Pointer<Uint8> get pointer => _pointer;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Libc.instance.free(_pointer);
  }
}
