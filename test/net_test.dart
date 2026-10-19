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
  test('loopback TCP echo through io_uring network ops', () {
    final ring = IoUring(entries: 16);
    final fds = <int>[];
    UringSockAddr? bindAddress;
    UringSockAddr? connectAddress;
    UringSockAddr? acceptAddress;
    UringBuffer? addrLen;
    UringBuffer? sendBuffer;
    UringBuffer? recvBuffer;

    try {
      final server = _call(ring, const SocketOp(), userData: 1);
      expect(server.isError, isFalse, reason: 'SOCKET: $server');
      final serverFd = server.result;
      fds.add(serverFd);

      bindAddress = UringSockAddr.inet(port: 0);
      final bound = _call(
        ring,
        BindOp(
          fd: serverFd,
          sockaddr: bindAddress.pointer,
          addrlen: bindAddress.length,
        ),
        userData: 2,
      );
      expect(bound.result, 0, reason: 'BIND: $bound');

      final listening = _call(
        ring,
        ListenOp(fd: serverFd, backlog: 8),
        userData: 3,
      );
      expect(listening.result, 0, reason: 'LISTEN: $listening');

      final port = Posix.localPort(serverFd);
      expect(port, greaterThan(0));

      final client = _call(ring, const SocketOp(), userData: 4);
      expect(client.isError, isFalse, reason: 'SOCKET(client): $client');
      final clientFd = client.result;
      fds.add(clientFd);

      connectAddress = UringSockAddr.inet(port: port);
      final connected = _call(
        ring,
        ConnectOp(
          fd: clientFd,
          sockaddr: connectAddress.pointer,
          addrlen: connectAddress.length,
        ),
        userData: 5,
      );
      expect(connected.result, 0, reason: 'CONNECT: $connected');

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
        userData: 6,
      );
      expect(accepted.isError, isFalse, reason: 'ACCEPT: $accepted');
      final acceptedFd = accepted.result;
      fds.add(acceptedFd);

      sendBuffer = UringBuffer.allocate(16);
      _fill(sendBuffer, 'ping');
      final sent = _call(
        ring,
        SendOp(fd: clientFd, buffer: sendBuffer.pointer, length: 4),
        userData: 7,
      );
      expect(sent.result, 4, reason: 'SEND: $sent');

      recvBuffer = UringBuffer.allocate(16);
      final received = _call(
        ring,
        RecvOp(fd: acceptedFd, buffer: recvBuffer.pointer, length: 16),
        userData: 8,
      );
      expect(received.result, 4, reason: 'RECV: $received');
      expect(utf8.decode(recvBuffer.bytes.sublist(0, received.result)), 'ping');

      _fill(sendBuffer, 'pong');
      final echoed = _call(
        ring,
        SendOp(fd: acceptedFd, buffer: sendBuffer.pointer, length: 4),
        userData: 9,
      );
      expect(echoed.result, 4, reason: 'SEND(echo): $echoed');

      final clientRecv = _call(
        ring,
        RecvOp(fd: clientFd, buffer: recvBuffer.pointer, length: 16),
        userData: 10,
      );
      expect(clientRecv.result, 4, reason: 'RECV(client): $clientRecv');
      expect(
        utf8.decode(recvBuffer.bytes.sublist(0, clientRecv.result)),
        'pong',
      );

      final shutdown = _call(
        ring,
        ShutdownOp(fd: clientFd, how: SocketConstants.shutWr),
        userData: 11,
      );
      expect(shutdown.result, 0, reason: 'SHUTDOWN: $shutdown');
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
      recvBuffer?.dispose();
      sendBuffer?.dispose();
      acceptAddress?.dispose();
      connectAddress?.dispose();
      bindAddress?.dispose();
    }
  });

  test('SOCKET op reports its fd and SHUTDOWN rejects bad fd', () {
    final ring = IoUring(entries: 8);
    try {
      final socket = _call(ring, const SocketOp());
      expect(socket.isError, isFalse);
      final fd = socket.result;
      expect(fd, greaterThanOrEqualTo(0));
      try {
        final shutdown = _call(ring, const ShutdownOp(fd: -1));
        expect(shutdown.isError, isTrue);
        expect(shutdown.errno, 9); // EBADF
      } finally {
        Posix.close(fd);
      }
    } finally {
      ring.close();
    }
  });
}
