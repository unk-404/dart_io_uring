import 'dart:ffi';

typedef _SyscallNative = Int64 Function(
  Int64,
  VarArgs<(Int64, Int64, Int64, Int64, Int64, Int64)>,
);
typedef _SyscallDart = int Function(int, int, int, int, int, int, int);

typedef _MmapNative = Pointer<Uint8> Function(
  Pointer<Void>,
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int64,
);
typedef _MmapDart = Pointer<Uint8> Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  int,
);

typedef _MunmapNative = Int32 Function(Pointer<Void>, IntPtr);
typedef _MunmapDart = int Function(Pointer<Void>, int);

typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);

typedef _OpenAtNative = Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32);
typedef _OpenAtDart = int Function(int, Pointer<Uint8>, int, int);

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);

typedef _CallocNative = Pointer<Uint8> Function(IntPtr, IntPtr);
typedef _CallocDart = Pointer<Uint8> Function(int, int);

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

typedef _ErrnoLocationNative = Pointer<Int32> Function();
typedef _ErrnoLocationDart = Pointer<Int32> Function();

typedef _StrErrorNative = Pointer<Uint8> Function(Int32);
typedef _StrErrorDart = Pointer<Uint8> Function(int);

typedef _PthreadMutexInitNative = Int32 Function(Pointer<Uint8>, Pointer<Void>);
typedef _PthreadMutexInitDart = int Function(Pointer<Uint8>, Pointer<Void>);

typedef _PthreadMutexLockNative = Int32 Function(Pointer<Uint8>);
typedef _PthreadMutexLockDart = int Function(Pointer<Uint8>);

typedef _EventfdNative = Int32 Function(Uint32, Int32);
typedef _EventfdDart = int Function(int, int);

typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);

/// Thin, lazy bindings to the handful of libc symbols io_uring needs.
///
/// No native code is compiled or linked by this package; [DynamicLibrary.process]
/// resolves symbols that the Dart VM process already has from libc.
final class Libc {
  Libc._(this._library);

  /// Process-wide singleton. Initialization is lazy, so merely importing this
  /// library on a non-Linux platform does not touch native symbols.
  static final Libc instance = Libc._(DynamicLibrary.process());

  final DynamicLibrary _library;

  late final _SyscallDart _syscall = _lookupSyscall();

  _SyscallDart _lookupSyscall() {
    final symbol = _library.lookup('syscall');
    return symbol
        .cast<NativeFunction<_SyscallNative>>()
        .asFunction<_SyscallDart>();
  }

  late final _MmapDart _mmap = _library.lookupFunction<_MmapNative, _MmapDart>(
    'mmap',
  );
  late final _MunmapDart _munmap = _library
      .lookupFunction<_MunmapNative, _MunmapDart>('munmap');
  late final _CloseDart _close = _library
      .lookupFunction<_CloseNative, _CloseDart>('close');
  late final _OpenAtDart _openat = _library
      .lookupFunction<_OpenAtNative, _OpenAtDart>('openat');
  late final _MallocDart _malloc = _library
      .lookupFunction<_MallocNative, _MallocDart>('malloc');
  late final _CallocDart _calloc = _library
      .lookupFunction<_CallocNative, _CallocDart>('calloc');
  late final _FreeDart _free = _library.lookupFunction<_FreeNative, _FreeDart>(
    'free',
  );
  late final _ErrnoLocationDart _errnoLocation = _lookupErrnoLocation();
  late final _StrErrorDart _strerror = _library
      .lookupFunction<_StrErrorNative, _StrErrorDart>('strerror');
  late final _EventfdDart _eventfd = _library
      .lookupFunction<_EventfdNative, _EventfdDart>('eventfd');
  late final _ReadDart _read = _library.lookupFunction<_ReadNative, _ReadDart>(
    'read',
  );

  _ErrnoLocationDart _lookupErrnoLocation() {
    return _library.lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
      '__errno_location',
    );
  }

  /// Calls libc's variadic `syscall(long, ...)` with six integer arguments.
  ///
  /// glibc/musl wrap the raw syscall: on failure they return `-1` and set
  /// `errno` (they do *not* return `-errno`).
  int syscall6(int number, int a1, int a2, int a3, int a4, int a5, int a6) =>
      _syscall(number, a1, a2, a3, a4, a5, a6);

  Pointer<Uint8> mmap(
    int length, {
    required int fd,
    required int offset,
    int prot = 0x3,
    int flags = 0x8001, // MAP_SHARED | MAP_POPULATE
  }) => _mmap(Pointer<Void>.fromAddress(0), length, prot, flags, fd, offset);

  int munmap(Pointer<Uint8> address, int length) =>
      _munmap(address.cast<Void>(), length);

  int close(int fd) => _close(fd);

  int openat(int dirfd, Pointer<Uint8> path, int flags, int mode) =>
      _openat(dirfd, path, flags, mode);

  Pointer<Uint8> malloc(int size) => _malloc(size);

  Pointer<Uint8> calloc(int count, int size) => _calloc(count, size);

  void free(Pointer<Uint8> pointer) => _free(pointer);

  int eventfd(int initval, int flags) => _eventfd(initval, flags);

  int read(int fd, Pointer<Uint8> buffer, int count) =>
      _read(fd, buffer, count);

  Pointer<Int32> errnoLocation() => _errnoLocation();

  /// Current thread's `errno`.
  int get errno => _errnoLocation().value;

  /// A cheap call that the Dart compiler cannot reorder memory operations
  /// across. On x86_64 (TSO) this is enough for our acquire/release needs.
  void compilerBarrier() {
    _errnoLocation();
  }

  /// Human-readable errno string, copied out of libc's static buffer.
  String strerror(int code) {
    final pointer = _strerror(code);
    if (pointer.address == 0) return 'errno $code';
    final bytes = <int>[];
    for (var i = 0; i < 256; i++) {
      final byte = (pointer + i).value;
      if (byte == 0) break;
      bytes.add(byte);
    }
    return String.fromCharCodes(bytes);
  }

  late final _PthreadMutexInitDart _pthreadMutexInit = _library
      .lookupFunction<_PthreadMutexInitNative, _PthreadMutexInitDart>(
        'pthread_mutex_init',
      );
  late final _PthreadMutexLockDart _pthreadMutexLock = _library
      .lookupFunction<_PthreadMutexLockNative, _PthreadMutexLockDart>(
        'pthread_mutex_lock',
      );
  late final _PthreadMutexLockDart _pthreadMutexUnlock = _library
      .lookupFunction<_PthreadMutexLockNative, _PthreadMutexLockDart>(
        'pthread_mutex_unlock',
      );

  int pthreadMutexInit(Pointer<Uint8> mutex) =>
      _pthreadMutexInit(mutex, Pointer<Void>.fromAddress(0));

  int pthreadMutexLock(Pointer<Uint8> mutex) => _pthreadMutexLock(mutex);

  int pthreadMutexUnlock(Pointer<Uint8> mutex) => _pthreadMutexUnlock(mutex);
}
