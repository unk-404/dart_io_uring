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

void main() {
  test('registered buf_ring drives multishot recv', () {
    final ring = IoUring(entries: 16);
    final fds = <int>[];
    UringSockAddr? bindAddress;
    UringSockAddr? connectAddress;
    UringSockAddr? acceptAddress;
    UringBuffer? addrLen;
    UringBuffer? sendBuffer;
    UringBuffer? blocks;

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

      final bufRing = ring.registerBufRing(entries: 2, bufferGroup: 9);
      blocks = UringBuffer.allocate(2 * 1024);
      bufRing.add(buffer: blocks.pointer, length: 1024, bufferId: 0);
      bufRing.add(buffer: blocks.pointer + 1024, length: 1024, bufferId: 1);

      ring.push(
        RecvMultiOp(fd: acceptedFd, bufferGroup: 9, length: 1024),
        userData: 200,
      );
      ring.submit();

      sendBuffer = UringBuffer.allocate(16);

      void send(String text) {
        final bytes = utf8.encode(text);
        sendBuffer!.bytes.setRange(0, bytes.length, bytes);
        expect(
          Posix.write(clientFd, sendBuffer.pointer, bytes.length),
          bytes.length,
        );
      }

      send('one');
      final first = ring.waitCqe();
      expect(first.userData, 200);
      expect(first.result, 3, reason: 'first: $first');
      expect(first.hasBuffer, isTrue);
      expect(first.more, isTrue);
      expect(first.bufferId, 0);
      expect(
        utf8.decode(blocks.bytes.sublist(0 * 1024, 0 * 1024 + first.result)),
        'one',
      );

      send('two');
      final second = ring.waitCqe();
      expect(second.result, 3, reason: 'second: $second');
      expect(second.hasBuffer, isTrue);
      expect(second.more, isTrue);
      expect(second.bufferId, 1);
      expect(
        utf8.decode(blocks.bytes.sublist(1 * 1024, 1 * 1024 + second.result)),
        'two',
      );

      send('three');
      final exhausted = ring.waitCqe();
      expect(exhausted.userData, 200);
      expect(exhausted.result, -105, reason: 'exhausted: $exhausted');
      expect(exhausted.more, isFalse);

      ring.unregisterBufRing(9);
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
      blocks?.dispose();
      sendBuffer?.dispose();
      acceptAddress?.dispose();
      connectAddress?.dispose();
      bindAddress?.dispose();
    }
  });

  test('close unregisters still-registered buf rings', () {
    final ring = IoUring(entries: 8);
    final block = UringBuffer.allocate(1024);
    try {
      final bufRing = ring.registerBufRing(entries: 2, bufferGroup: 1);
      bufRing.add(buffer: block.pointer, length: 1024, bufferId: 0);
      ring.close();
    } finally {
      block.dispose();
    }
  });
}
