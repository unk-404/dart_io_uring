import 'dart:ffi';

/// `struct io_uring_sqe` (64 bytes).
///
/// Several fields are C unions in the kernel header. For the operations this
/// package encodes we expose the canonical member; advanced ops can write the
/// overlapping members directly through the pointer.
final class IoUringSqe extends Struct {
  @Uint8()
  external int opcode;
  @Uint8()
  external int flags;
  @Uint16()
  external int ioprio;
  @Int32()
  external int fd;
  @Uint64()
  external int off;
  @Uint64()
  external int addr;
  @Uint32()
  external int len;
  @Uint32()
  external int opFlags;
  @Uint64()
  external int userData;
  @Uint16()
  external int bufIndex;
  @Uint16()
  external int personality;
  @Int32()
  external int spliceFdIn;
  @Uint64()
  external int addr3;
  @Uint64()
  external int pad2;
}
