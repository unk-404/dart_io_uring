@TestOn('linux')
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:io_uring/io_uring.dart';
import 'package:test/test.dart';

IoUringCompletion _call(IoUring ring, UringOp operation, {int userData = 0}) {
  ring.push(operation, userData: userData);
  ring.submitAndWait(1);
  return ring.waitCqe();
}

void _fill(UringBuffer buffer, String text) {
  final bytes = utf8.encode(text);
  buffer.bytes.setRange(0, bytes.length, bytes);
}

void main() {
  test('provided buffers drive multishot recv until -ENOBUFS', () {
    final ring = IoUring(entries: 16);
    final fds = <int>[];
    UringSockAddr? bindAddress;
    UringSockAddr? connectAddress;
    UringSockAddr? acceptAddress;
    UringBuffer? addrLen;
    UringBuffer? sendBuffer;
    UringBuffer? provided;

    try {
      final server = _call(ring, const SocketOp());
      expect(server.isError, isFalse, reason: 'SOCKET: $server');
      final serverFd = server.result;
      fds.add(serverFd);

      bindAddress = UringSockAddr.inet(port: 0);
      expect(
        _call(
          ring,
          BindOp(
            fd: serverFd,
            sockaddr: bindAddress.pointer,
            addrlen: bindAddress.length,
          ),
        ).result,
        0,
      );
      expect(_call(ring, ListenOp(fd: serverFd, backlog: 8)).result, 0);

      final port = Posix.localPort(serverFd);
      expect(port, greaterThan(0));

      final client = _call(ring, const SocketOp());
      expect(client.isError, isFalse, reason: 'SOCKET(client): $client');
      final clientFd = client.result;
      fds.add(clientFd);

      connectAddress = UringSockAddr.inet(port: port);
      expect(
        _call(
          ring,
          ConnectOp(
            fd: clientFd,
            sockaddr: connectAddress.pointer,
            addrlen: connectAddress.length,
          ),
        ).result,
        0,
      );

      acceptAddress = UringSockAddr.inet(port: 0);
      addrLen = UringBuffer.allocate(4);
      addrLen.pointer.cast<Uint32>().value = acceptAddress.length;
      final accepted = _call(
        ring,
        AcceptOp(
          fd: serverFd,
          addr: acceptAddress.pointer,
          addrLen: addrLen.pointer.cast<Uint32>(),
        ),
      );
      expect(accepted.isError, isFalse, reason: 'ACCEPT: $accepted');
      final acceptedFd = accepted.result;
      fds.add(acceptedFd);

      provided = UringBuffer.allocate(2 * 1024);
      final provide = _call(
        ring,
        ProvideBuffersOp(
          buffer: provided.pointer,
          length: 1024,
          count: 2,
          bufferGroup: 7,
        ),
        userData: 90,
      );
      expect(provide.result, 0, reason: 'PROVIDE_BUFFERS: $provide');

      ring.push(
        RecvMultiOp(fd: acceptedFd, bufferGroup: 7, length: 1024),
        userData: 100,
      );
      ring.submit();

      sendBuffer = UringBuffer.allocate(16);

      _fill(sendBuffer, 'one');
      expect(Posix.write(clientFd, sendBuffer.pointer, 3), 3);
      final first = ring.waitCqe();
      expect(first.userData, 100);
      expect(first.result, 3, reason: 'first: $first');
      expect(first.hasBuffer, isTrue);
      expect(first.more, isTrue);
      expect(first.bufferId, 0);
      expect(
        utf8.decode(provided.bytes.sublist(0 * 1024, 0 * 1024 + first.result)),
        'one',
      );

      _fill(sendBuffer, 'two');
      expect(Posix.write(clientFd, sendBuffer.pointer, 3), 3);
      final second = ring.waitCqe();
      expect(second.result, 3, reason: 'second: $second');
      expect(second.hasBuffer, isTrue);
      expect(second.more, isTrue);
      expect(second.bufferId, 1);
      expect(
        utf8.decode(provided.bytes.sublist(1 * 1024, 1 * 1024 + second.result)),
        'two',
      );

      _fill(sendBuffer, 'three');
      expect(Posix.write(clientFd, sendBuffer.pointer, 5), 5);
      final exhausted = ring.waitCqe();
      expect(exhausted.userData, 100);
      expect(exhausted.result, -105, reason: 'exhausted: $exhausted');
      expect(exhausted.more, isFalse);
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
      provided?.dispose();
      sendBuffer?.dispose();
      acceptAddress?.dispose();
      connectAddress?.dispose();
      bindAddress?.dispose();
    }
  });
}
