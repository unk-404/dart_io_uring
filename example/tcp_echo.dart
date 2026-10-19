import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:io_uring/io_uring.dart';

/// A single-connection TCP echo server built entirely from io_uring ops.
///
/// Run it, then connect with e.g. `nc 127.0.0.1 <port>`.
Future<void> main() async {
  if (!Platform.isLinux) {
    stderr.writeln('io_uring is Linux-only; run this example in WSL or Linux.');
    exitCode = 1;
    return;
  }

  final ring = IoUring(entries: 32);
  final fds = <int>[];
  UringSockAddr? bindAddress;
  UringSockAddr? acceptAddress;
  UringBuffer? addrLen;
  UringBuffer? buffer;

  try {
    final server = _run(ring, const SocketOp());
    _check(server, 'SOCKET');
    final serverFd = server.result;
    fds.add(serverFd);

    bindAddress = UringSockAddr.inet(port: 0);
    final bound = _run(
      ring,
      BindOp(
        fd: serverFd,
        sockaddr: bindAddress.pointer,
        addrlen: bindAddress.length,
      ),
    );
    _check(bound, 'BIND');

    final listening = _run(ring, ListenOp(fd: serverFd, backlog: 16));
    _check(listening, 'LISTEN');

    final port = Posix.localPort(serverFd);
    stdout.writeln('listening on 127.0.0.1:$port');
    await stdout.flush();

    acceptAddress = UringSockAddr.inet(port: 0);
    addrLen = UringBuffer.allocate(4);
    addrLen.pointer.cast<Uint32>().value = acceptAddress.length;
    final accepted = _run(
      ring,
      AcceptOp(
        fd: serverFd,
        addr: acceptAddress.pointer,
        addrLen: addrLen.pointer.cast<Uint32>(),
      ),
    );
    _check(accepted, 'ACCEPT');
    final clientFd = accepted.result;
    fds.add(clientFd);
    stdout.writeln('client connected');
    await stdout.flush();

    buffer = UringBuffer.allocate(4096);
    while (true) {
      final received = _run(
        ring,
        RecvOp(fd: clientFd, buffer: buffer.pointer, length: buffer.length),
      );
      _check(received, 'RECV');
      if (received.result == 0) break;

      final text = utf8.decode(buffer.bytes.sublist(0, received.result));
      stdout.write('client: $text');
      await stdout.flush();

      final sent = _run(
        ring,
        SendOp(fd: clientFd, buffer: buffer.pointer, length: received.result),
      );
      _check(sent, 'SEND');
    }
  } finally {
    for (final fd in fds.reversed) {
      try {
        Posix.close(fd);
      } on Object {
        // Best-effort cleanup.
      }
    }
    ring.close();
    addrLen?.dispose();
    buffer?.dispose();
    acceptAddress?.dispose();
    bindAddress?.dispose();
  }
}

IoUringCompletion _run(IoUring ring, UringOp operation) {
  ring.push(operation);
  ring.submitAndWait(1);
  return ring.waitCqe();
}

void _check(IoUringCompletion completion, String operation) {
  if (completion.isError) {
    throw IoUringException(operation, completion.errno);
  }
}
