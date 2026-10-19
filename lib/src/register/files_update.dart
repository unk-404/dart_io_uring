import 'dart:ffi';

/// `struct io_uring_files_update` (16 bytes).
final class UringFilesUpdate extends Struct {
  @Uint32()
  external int offset;
  @Uint32()
  external int resv;
  @Uint64()
  external int fds;
}
