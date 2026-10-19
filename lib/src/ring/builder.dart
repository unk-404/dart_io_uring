import '../ffi/constants.dart';
import 'io_uring.dart';

/// Fluent builder for [IoUring] setup flags.
final class IoUringBuilder {
  int _entries = 256;
  int _flags = 0;
  int _cqEntries = 0;
  int _sqThreadCpu = 0;
  int _sqThreadIdle = 0;

  IoUringBuilder entries(int value) {
    _entries = value;
    return this;
  }

  IoUringBuilder cqsize(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', 'must be positive');
    }
    _cqEntries = value;
    return this;
  }

  IoUringBuilder iopoll() {
    _flags |= IoUringSetupFlags.iopoll;
    return this;
  }

  IoUringBuilder sqpoll({int idle = 1000, int? cpu}) {
    _flags |= IoUringSetupFlags.sqpoll;
    _sqThreadIdle = idle;
    if (cpu != null) {
      _flags |= IoUringSetupFlags.sqAff;
      _sqThreadCpu = cpu;
    }
    return this;
  }

  IoUringBuilder coopTaskrun() {
    _flags |= IoUringSetupFlags.coopTaskrun;
    return this;
  }

  IoUringBuilder singleIssuer() {
    _flags |= IoUringSetupFlags.singleIssuer;
    return this;
  }

  IoUringBuilder deferTaskrun() {
    _flags |= IoUringSetupFlags.deferTaskrun;
    return this;
  }

  IoUringBuilder submitAll() {
    _flags |= IoUringSetupFlags.submitAll;
    return this;
  }

  IoUring build() {
    return IoUring(
      entries: _entries,
      flags: _flags,
      cqEntries: _cqEntries,
      sqThreadCpu: _sqThreadCpu,
      sqThreadIdle: _sqThreadIdle,
    );
  }
}
