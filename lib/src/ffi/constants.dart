/// Constants from the Linux io_uring UAPI (`linux/io_uring.h`).
///
/// They are copied here (instead of generated from a C header) so the package
/// has zero native build steps. Values are stable kernel ABI.
library;

/// io_uring syscall numbers.
///
/// Both the x86_64 syscall table and the generic (aarch64/riscv64) table use
/// the same numbers for io_uring.
abstract final class IoUringSyscall {
  static const int setup = 425;
  static const int enter = 426;
  static const int register = 427;
}

/// `mmap(2)` offsets used by io_uring.
abstract final class IoUringMmapOffset {
  static const int sqRing = 0x00000000;
  static const int cqRing = 0x08000000;
  static const int sqes = 0x10000000;
}

/// Flags for `io_uring_enter(2)`.
abstract final class IoUringEnterFlags {
  static const int getEvents = 1 << 0;
  static const int sqWakeup = 1 << 1;
  static const int sqWait = 1 << 2;
  static const int extArg = 1 << 3;
}

/// Flags for `io_uring_setup(2)` (`io_uring_params.flags`).
abstract final class IoUringSetupFlags {
  static const int iopoll = 1 << 0;
  static const int sqpoll = 1 << 1;
  static const int sqAff = 1 << 2;
  static const int cqsize = 1 << 3;
  static const int clamp = 1 << 4;
  static const int attachWq = 1 << 5;
  static const int rDisabled = 1 << 6;
  static const int submitAll = 1 << 7;
  static const int coopTaskrun = 1 << 8;
  static const int taskrunFlag = 1 << 9;
  static const int sqe128 = 1 << 10;
  static const int cqe32 = 1 << 11;
  static const int singleIssuer = 1 << 12;
  static const int deferTaskrun = 1 << 13;
  static const int noMmap = 1 << 14;
  static const int registeredFdOnly = 1 << 15;
  static const int noSqarray = 1 << 16;
  static const int hybridIopoll = 1 << 17;
  static const int cqeMixed = 1 << 18;
  static const int sqeMixed = 1 << 19;
  static const int sqRewind = 1 << 20;
}

/// Feature bits reported back in `io_uring_params.features`.
abstract final class IoUringFeatures {
  static const int singleMmap = 1 << 0;
  static const int noDrop = 1 << 1;
  static const int submitStable = 1 << 2;
  static const int rwCurPos = 1 << 3;
  static const int curPersonality = 1 << 4;
  static const int fastPoll = 1 << 5;
  static const int poll32Bits = 1 << 6;
  static const int sqpollNonfixed = 1 << 7;
  static const int extArg = 1 << 8;
  static const int nativeWorkers = 1 << 9;
  static const int rsrcTags = 1 << 10;
  static const int cqeSkip = 1 << 11;
  static const int linkedFile = 1 << 12;
  static const int regRegRing = 1 << 13;
  static const int recvSendBundle = 1 << 14;
  static const int minTimeout = 1 << 15;
  static const int rwAttr = 1 << 16;
  static const int noIowait = 1 << 17;
}

/// Status bits in the submission queue `flags` field.
abstract final class IoUringSqFlags {
  static const int needWakeup = 1 << 0;
  static const int cqOverflow = 1 << 1;
  static const int taskrun = 1 << 2;
}

/// Bits in a completion queue entry's `flags` field.
abstract final class IoUringCqeFlags {
  static const int buffer = 1 << 0;
  static const int more = 1 << 1;
  static const int sockNonEmpty = 1 << 2;
  static const int notif = 1 << 3;
  static const int bufMore = 1 << 4;
  static const int skip = 1 << 5;
}

/// Bits in a submission queue entry's `flags` field (`IOSQE_*`).
abstract final class IoUringSqeFlags {
  static const int fixedFile = 1 << 0;
  static const int ioDrain = 1 << 1;
  static const int ioLink = 1 << 2;
  static const int ioHardlink = 1 << 3;
  static const int async = 1 << 4;
  static const int bufferSelect = 1 << 5;
  static const int cqeSkipSuccess = 1 << 6;
}

/// `IORING_OP_*` values. Keep in sync with `linux/io_uring.h`.
abstract final class IoUringOpcode {
  static const int nop = 0;
  static const int readv = 1;
  static const int writev = 2;
  static const int fsync = 3;
  static const int readFixed = 4;
  static const int writeFixed = 5;
  static const int pollAdd = 6;
  static const int pollRemove = 7;
  static const int syncFileRange = 8;
  static const int sendmsg = 9;
  static const int recvmsg = 10;
  static const int timeout = 11;
  static const int timeoutRemove = 12;
  static const int accept = 13;
  static const int asyncCancel = 14;
  static const int linkTimeout = 15;
  static const int connect = 16;
  static const int fallocate = 17;
  static const int openat = 18;
  static const int close = 19;
  static const int filesUpdate = 20;
  static const int statx = 21;
  static const int read = 22;
  static const int write = 23;
  static const int fadvise = 24;
  static const int madvise = 25;
  static const int send = 26;
  static const int recv = 27;
  static const int openat2 = 28;
  static const int epollCtl = 29;
  static const int splice = 30;
  static const int provideBuffers = 31;
  static const int removeBuffers = 32;
  static const int tee = 33;
  static const int shutdown = 34;
  static const int renameat = 35;
  static const int unlinkat = 36;
  static const int mkdirat = 37;
  static const int symlinkat = 38;
  static const int linkat = 39;
  static const int msgRing = 40;
  static const int fsetxattr = 41;
  static const int setxattr = 42;
  static const int fgetxattr = 43;
  static const int getxattr = 44;
  static const int socket = 45;
  static const int uringCmd = 46;
  static const int sendZc = 47;
  static const int sendmsgZc = 48;
  static const int readMultishot = 49;
  static const int waitid = 50;
  static const int futexWait = 51;
  static const int futexWake = 52;
  static const int futexWaitv = 53;
  static const int fixedFdInstall = 54;
  static const int ftruncate = 55;
  static const int bind = 56;
  static const int listen = 57;
  static const int recvZc = 58;
  static const int epollWait = 59;
  static const int readvFixed = 60;
  static const int writevFixed = 61;
  static const int pipe = 62;
  static const int nop128 = 63;
  static const int uringCmd128 = 64;
}

/// `io_uring_register(2)` opcodes.
abstract final class IoUringRegisterOpcode {
  static const int buffers = 0;
  static const int unregisterBuffers = 1;
  static const int files = 2;
  static const int unregisterFiles = 3;
  static const int eventfd = 4;
  static const int unregisterEventfd = 5;
  static const int filesUpdate = 6;
  static const int eventfdAsync = 7;
  static const int probe = 8;
}

/// Socket constants needed by the network operations.
abstract final class SocketConstants {
  static const int afInet = 2;
  static const int afInet6 = 10;

  static const int sockStream = 1;
  static const int sockDgram = 2;

  static const int ipprotoTcp = 6;

  static const int shutRd = 0;
  static const int shutWr = 1;
  static const int shutRdWr = 2;
}

/// Flags for `IORING_OP_SPLICE` / `IORING_OP_TEE`.
abstract final class SpliceFlags {
  /// `fd_in` is an index into the registered-file table.
  static const int fdInFixed = 0x80000000;
}

/// Minimal POSIX constants needed by the raw-fd layer.
abstract final class PosixConstants {
  static const int atFdCwd = -100;

  static const int oRdonly = 0x0000;
  static const int oWronly = 0x0001;
  static const int oRdwr = 0x0002;
  static const int oCreat = 0x0040;
  static const int oExcl = 0x0080;
  static const int oTrunc = 0x0200;
  static const int oAppend = 0x0400;
  static const int oCloexec = 0x080000;
}
