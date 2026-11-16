import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_errors.dart';
import 'network_settings.dart';

/// RFC 1928 CONNECT only, with no authentication. Domain names are sent to the
/// proxy unchanged; only the proxy endpoint is resolved on this device.
///
/// RawSocket is intentional: it lets cancellation close the TCP connection
/// during both SOCKS negotiation and TLS negotiation, and lets each handshake
/// read exactly its own bytes without losing following response data.
class Socks5ConnectionAttempt {
  Socks5ConnectionAttempt(this.settings, this.destination, {this.context}) {
    task = ConnectionTask.fromSocket(_connect(), cancel);
  }

  final NetworkSettings settings;
  final Uri destination;
  final SecurityContext? context;
  late final ConnectionTask<Socket> task;
  ConnectionTask<RawSocket>? _connecting;
  RawSocket? _tcp;
  RawSocket? _secured;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _connecting?.cancel();
    unawaited(_secured?.close());
    // The original raw connection remains cancellable while secure() awaits
    // the TLS handshake; a high-level Socket would detach and lose that handle.
    unawaited(_tcp?.close());
  }

  void _checkCancelled() {
    if (_cancelled) throw const NetworkCancelledException();
  }

  Future<Socket> _connect() async {
    try {
      final connecting = await RawSocket.startConnect(
        settings.normalizedHost,
        settings.port,
      );
      _connecting = connecting;
      if (_cancelled) connecting.cancel();
      final raw = await connecting.socket;
      _tcp = raw;
      _checkCancelled();
      raw.setOption(SocketOption.tcpNoDelay, true);
      final handshake = _Handshake(raw);
      await handshake.write([5, 1, 0]);
      final method = await handshake.read(2);
      if (method[0] != 5 || method[1] != 0) {
        throw const NetworkException(
          NetworkErrorKind.proxy,
          'SOCKS5 代理拒绝无认证连接；当前版本不支持需要账号密码的代理。',
        );
      }
      final host = destination.host;
      final address = InternetAddress.tryParse(host);
      final target = <int>[];
      if (address != null) {
        target.add(address.type == InternetAddressType.IPv4 ? 1 : 4);
        target.addAll(address.rawAddress);
      } else {
        // Uri normalizes internationalized host names to their ASCII form.
        final name = ascii.encode(host);
        if (name.isEmpty || name.length > 255) {
          throw const NetworkException(NetworkErrorKind.proxy, '目标主机名过长。');
        }
        target.addAll([3, name.length, ...name]);
      }
      final port = destination.port;
      await handshake.write([5, 1, 0, ...target, port >> 8, port & 255]);
      final reply = await handshake.read(4);
      if (reply[0] != 5 || reply[2] != 0 || reply[1] != 0) {
        throw const NetworkException(
          NetworkErrorKind.proxy,
          'SOCKS5 代理无法连接目标服务器，请检查代理规则和线路。',
        );
      }
      switch (reply[3]) {
        case 1:
          await handshake.read(4);
        case 4:
          await handshake.read(16);
        case 3:
          final length = (await handshake.read(1)).single;
          if (length == 0) {
            throw const NetworkException(
              NetworkErrorKind.proxy,
              'SOCKS5 代理返回了无效地址。',
            );
          }
          await handshake.read(length);
        default:
          throw const NetworkException(
            NetworkErrorKind.proxy,
            'SOCKS5 代理返回了无效地址类型。',
          );
      }
      await handshake.read(2);
      _checkCancelled();
      final subscription = handshake.release();
      if (destination.scheme == 'https') {
        // No onBadCertificate override: platform trust and target-host
        // verification remain mandatory, exactly as for a direct HttpClient.
        final secured = await RawSecureSocket.secure(
          raw,
          subscription: subscription,
          host: host,
          context: context,
        );
        _secured = secured;
        _checkCancelled();
        return _RawByteSocket(secured);
      }
      return _RawByteSocket(raw, subscription: subscription);
    } catch (_) {
      unawaited(_secured?.close());
      unawaited(_tcp?.close());
      rethrow;
    }
  }
}

class _Handshake {
  _Handshake(this.socket) {
    socket.readEventsEnabled = false;
    socket.writeEventsEnabled = false;
    subscription = socket.listen(
      _event,
      onError: _fail,
      onDone: () {
        _fail(
          const NetworkException(NetworkErrorKind.proxy, 'SOCKS5 代理提前关闭连接。'),
        );
      },
    );
  }

  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> subscription;
  Completer<void>? _readable;
  Completer<void>? _writable;
  Object? _error;

  void _event(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      socket.readEventsEnabled = false;
      _readable?.complete();
      _readable = null;
    } else if (event == RawSocketEvent.write) {
      _writable?.complete();
      _writable = null;
    } else if (event == RawSocketEvent.readClosed ||
        event == RawSocketEvent.closed) {
      _fail(const NetworkException(NetworkErrorKind.proxy, 'SOCKS5 代理提前关闭连接。'));
    }
  }

  void _fail(Object error) {
    _error ??= error;
    _readable?.complete();
    _readable = null;
    _writable?.complete();
    _writable = null;
  }

  Future<Uint8List> read(int length) async {
    final result = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      if (_error case final error?) throw error;
      final chunk = socket.read(length - offset);
      if (chunk != null) {
        result.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      } else {
        final ready = _readable = Completer<void>();
        socket.readEventsEnabled = true;
        await ready.future;
      }
    }
    return result;
  }

  Future<void> write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_error case final error?) throw error;
      offset += socket.write(bytes, offset);
      if (offset < bytes.length) {
        final ready = _writable = Completer<void>();
        socket.writeEventsEnabled = true;
        await ready.future;
      }
    }
  }

  StreamSubscription<RawSocketEvent> release() {
    socket.readEventsEnabled = false;
    socket.writeEventsEnabled = false;
    return subscription;
  }
}

/// Adapts the already-negotiated raw connection to HttpClient's public Socket
/// interface. IOSink handles write ordering; raw write readiness supplies
/// backpressure instead of assuming a write accepts the whole buffer.
class _RawByteSocket extends Stream<Uint8List> implements Socket {
  _RawByteSocket(
    this._raw, {
    StreamSubscription<RawSocketEvent>? subscription,
  }) {
    _raw.readEventsEnabled = false;
    _raw.writeEventsEnabled = false;
    _input = StreamController<Uint8List>(
      onListen: () => _raw.readEventsEnabled = true,
      onPause: () => _raw.readEventsEnabled = false,
      onResume: () => _raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _subscription = subscription ?? _raw.listen(_event);
    _subscription
      ..onData(_event)
      ..onError(_fail)
      ..onDone(_readDone);
    _output = IOSink(_RawWriter(this));
    // A peer can close after HttpClient has cancelled its subscription.
    // Observe sink errors even when its caller no longer awaits done.
    unawaited(_output.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final RawSocket _raw;
  late final StreamSubscription<RawSocketEvent> _subscription;
  late final StreamController<Uint8List> _input;
  late final IOSink _output;
  Completer<void>? _writable;
  Object? _writeError;
  bool _destroyed = false;

  void _event(RawSocketEvent event) {
    if (event == RawSocketEvent.read && !_input.isClosed) {
      final bytes = _raw.read();
      if (bytes != null) _input.add(bytes);
    } else if (event == RawSocketEvent.write) {
      _writable?.complete();
      _writable = null;
    } else if (event == RawSocketEvent.readClosed) {
      _readDone();
    } else if (event == RawSocketEvent.closed) {
      _writeError ??= const SocketException('Connection closed');
      _writable?.complete();
      _writable = null;
      _readDone();
    }
  }

  void _readDone() {
    if (!_input.isClosed) unawaited(_input.close());
  }

  void _fail(Object error, [StackTrace? stack]) {
    _writeError ??= error;
    _writable?.complete();
    _writable = null;
    if (!_input.isClosed) _input.addError(error, stack);
    _readDone();
  }

  Future<void> _write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_writeError case final error?) throw error;
      if (_destroyed) throw const SocketException('Connection closed');
      offset += _raw.write(bytes, offset);
      if (offset < bytes.length) {
        final ready = _writable = Completer<void>();
        _raw.writeEventsEnabled = true;
        await ready.future;
      }
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _writeError ??= const SocketException('Connection closed');
    _writable?.complete();
    _writable = null;
    unawaited(_raw.close());
    _readDone();
  }

  @override
  Encoding get encoding => _output.encoding;
  @override
  set encoding(Encoding value) => _output.encoding = value;
  @override
  void add(List<int> data) => _output.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _output.addStream(stream);
  @override
  Future<void> close() => _output.close();
  @override
  Future<void> get done => _output.done;
  @override
  Future<void> flush() => _output.flush();
  @override
  InternetAddress get address => _raw.address;
  @override
  int get port => _raw.port;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get remotePort => _raw.remotePort;
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
  @override
  void write(Object? object) => _output.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _output.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _output.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _output.writeln(object);
}

class _RawWriter implements StreamConsumer<List<int>> {
  _RawWriter(this.socket);
  final _RawByteSocket socket;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await socket._write(chunk);
    }
  }

  @override
  Future<void> close() async => socket._raw.shutdown(SocketDirection.send);
}
