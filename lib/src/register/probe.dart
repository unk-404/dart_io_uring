import 'dart:ffi';

/// `struct io_uring_probe_op` (8 bytes).
final class IoUringProbeOp extends Struct {
  @Uint8()
  external int op;
  @Uint8()
  external int resv;
  @Uint16()
  external int flags;
  @Uint32()
  external int resv2;
}

/// `struct io_uring_probe` header; the `ops[]` flexible array follows it.
final class IoUringProbe extends Struct {
  @Uint8()
  external int lastOp;
  @Uint8()
  external int opsLen;
  @Uint16()
  external int resv;
  @Array(3)
  external Array<Uint32> resv2;
}

/// Result of `IORING_REGISTER_PROBE`.
final class IoUringProbeResult {
  IoUringProbeResult({required this.lastOp, required Map<int, int> ops})
    : ops = Map.unmodifiable(ops);

  /// Highest opcode the kernel reports support information for.
  final int lastOp;

  /// Opcode -> `IO_URING_OP_*` flags.
  final Map<int, int> ops;

  bool isSupported(int opcode) => ops.containsKey(opcode);

  int flagsOf(int opcode) => ops[opcode] ?? 0;

  @override
  String toString() =>
      'IoUringProbeResult(lastOp: $lastOp, supported: ${ops.length})';
}
