/// A pure-Dart, syscall-level interface to Linux io_uring.
library;

export 'src/buffer.dart';
export 'src/errors.dart';
export 'src/ffi/constants.dart'
    show
        IoUringCqeFlags,
        IoUringEnterFlags,
        IoUringOpcode,
        IoUringRegisterOpcode,
        IoUringSetupFlags,
        IoUringSqeFlags,
        IoUringTimeoutFlags,
        IoUringMultishotFlags,
        PollEvents,
        PosixConstants,
        SocketConstants,
        SpliceFlags;
export 'src/ops/op.dart';
export 'src/os/posix.dart';
export 'src/register/probe.dart' show IoUringProbeResult;
export 'src/ring/cqe.dart';
export 'src/ring/io_uring.dart';
export 'src/ring/params.dart'
    show IoUringCqOffsetsView, IoUringParameters, IoUringSqOffsetsView;
export 'src/ring/sqe.dart' show IoUringSqe;
