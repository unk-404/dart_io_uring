import 'dart:ffi';

import 'libc.dart';

/// Acquire/release barriers around SQ/CQ ring publication.
///
/// Linux io_uring requires userspace to publish the SQ tail with release
/// semantics and consume the CQ tail with acquire semantics. Dart does not
/// expose atomics, so:
///
/// * x86_64: plain loads/stores are ordered by TSO; a libc call is used as a
///   compiler barrier.
/// * aarch64: `libatomic`'s `__atomic_thread_fence` when available, otherwise
///   an uncontended `pthread_mutex` lock/unlock pair (acquire + release).
abstract interface class MemoryBarrier {
  void acquire();
  void release();

  static MemoryBarrier create() {
    final abi = Abi.current();
    if (abi == Abi.linuxX64) return _X64Barrier();
    if (abi == Abi.linuxArm64) {
      return _AtomicBarrier.tryCreate() ?? _PthreadBarrier.create();
    }
    throw UnsupportedError(
      'io_uring is only supported on Linux x86_64 and aarch64, got $abi',
    );
  }
}

final class _X64Barrier implements MemoryBarrier {
  @override
  void acquire() => Libc.instance.compilerBarrier();

  @override
  void release() => Libc.instance.compilerBarrier();
}

final class _AtomicBarrier implements MemoryBarrier {
  _AtomicBarrier(this._fence);

  final void Function(int) _fence;

  static MemoryBarrier? tryCreate() {
    try {
      final library = DynamicLibrary.open('libatomic.so.1');
      final fence = library
          .lookupFunction<Void Function(Int32), void Function(int)>(
            '__atomic_thread_fence',
          );
      return _AtomicBarrier(fence);
    } on Object {
      return null;
    }
  }

  // __ATOMIC_SEQ_CST == 5
  @override
  void acquire() => _fence(5);

  @override
  void release() => _fence(5);
}

final class _PthreadBarrier implements MemoryBarrier {
  _PthreadBarrier._(this._mutex);

  final Pointer<Uint8> _mutex;

  static MemoryBarrier create() {
    final libc = Libc.instance;
    // glibc's pthread_mutex_t is <= 48 bytes on 64-bit; 64 is safe.
    final mutex = libc.calloc(1, 64);
    if (mutex.address == 0) {
      throw StateError('Failed to allocate pthread_mutex_t');
    }
    final result = libc.pthreadMutexInit(mutex);
    if (result != 0) {
      libc.free(mutex);
      throw StateError('pthread_mutex_init failed: $result');
    }
    return _PthreadBarrier._(mutex);
  }

  @override
  void acquire() {
    Libc.instance.pthreadMutexLock(_mutex);
    Libc.instance.pthreadMutexUnlock(_mutex);
  }

  @override
  void release() {
    Libc.instance.pthreadMutexLock(_mutex);
    Libc.instance.pthreadMutexUnlock(_mutex);
  }
}
