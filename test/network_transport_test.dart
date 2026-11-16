import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/network/network_transport_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proxy endpoint validation', () {
    test('accepts explicit hosts and rejects URL/auth/invalid port input', () {
      for (final host in [
        '127.0.0.1',
        'localhost',
        'proxy.example',
        '::1',
        '[::1]',
      ]) {
        expect(
          NetworkSettings(mode: NetworkMode.socks5, host: host).validate(),
          isNull,
        );
      }
      for (final host in [
        'http://localhost',
        'user:password@localhost',
        'localhost:80',
        'a b',
        '256.1.1.1',
        '999999999999999999999999.1.1.1',
        '-bad.test',
        'a..b',
        '[not-ip]',
      ]) {
        expect(
          NetworkSettings(mode: NetworkMode.http, host: host).validate(),
          isNotNull,
          reason: host,
        );
      }
      expect(
        const NetworkSettings(mode: NetworkMode.http, port: 0).validate(),
        isNotNull,
      );
      expect(
        const NetworkSettings(mode: NetworkMode.http, port: 65536).validate(),
        isNotNull,
      );
    });

    test(
      'environment honors NO_PROXY and rejects unsupported schemes/auth',
      () {
        final uri = Uri.parse('https://image.example/file');
        expect(environmentProxyFor(uri, {}), 'DIRECT');
        expect(
          environmentProxyFor(uri, {'https_proxy': 'http://127.0.0.1:8080'}),
          'PROXY 127.0.0.1:8080',
        );
        expect(
          environmentProxyFor(uri, {
            'HTTPS_PROXY': 'http://127.0.0.1:8080',
            'NO_PROXY': 'image.example',
          }),
          'DIRECT',
        );
        for (final value in [
          'socks5://localhost:1080',
          'http://user:pass@localhost:80',
          'http://localhost:0',
        ]) {
          expect(
            () => environmentProxyFor(uri, {'https_proxy': value}),
            throwsA(isA<NetworkException>()),
          );
        }
      },
    );
  });

  group('native HTTP routing', () {
    test(
      'SOCKS5 redirects reject unsupported schemes, credentials and ports before connecting',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        final reached = <String>[];
        var redirect = '';
        origin.listen((request) async {
          reached.add(request.uri.path);
          if (request.uri.path == '/redirect') {
            request.response.statusCode = 302;
            request.response.contentLength = 0;
            request.response.headers.set(HttpHeaders.locationHeader, redirect);
          } else {
            request.response.write('unexpected redirected request');
          }
          await request.response.close();
        });
        final proxy = await _SocksProxy.start(forwardPort: origin.port);
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        addTearDown(service.dispose);
        for (final target in [
          'ftp://never-resolve.invalid:21/unexpected',
          // Same endpoint can reuse the first connection, skipping its factory.
          'ftp://never-resolve.invalid:${origin.port}/unexpected',
          'http://user:password@never-resolve.invalid:${origin.port}/unexpected',
          'http://never-resolve.invalid:70000/unexpected',
        ]) {
          redirect = target;
          reached.clear();
          proxy.targets.clear();
          await expectLater(
            service.get(
              Uri.parse('http://never-resolve.invalid:${origin.port}/redirect'),
              retry: false,
            ),
            throwsA(
              isA<NetworkException>().having(
                (error) => error.kind,
                'kind',
                NetworkErrorKind.invalidResponse,
              ),
            ),
          );
          expect(reached, ['/redirect']);
          expect(proxy.targets, ['never-resolve.invalid:${origin.port}']);
        }
      },
    );

    test(
      'ordinary HTTP redirects reuse the SOCKS tunnel and remain proxied',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        final reached = <String>[];
        origin.listen((request) async {
          reached.add(request.uri.path);
          if (request.uri.path == '/redirect') {
            request.response.statusCode = 302;
            request.response.contentLength = 0;
            request.response.headers.set(HttpHeaders.locationHeader, '/image');
          } else {
            request.response.write('redirected image');
          }
          await request.response.close();
        });
        final proxy = await _SocksProxy.start(forwardPort: origin.port);
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        addTearDown(service.dispose);
        final response = await service.get(
          Uri.parse('http://never-resolve.invalid:${origin.port}/redirect'),
          retry: false,
        );
        expect(response.body, 'redirected image');
        expect(reached, ['/redirect', '/image']);
        expect(proxy.targets, ['never-resolve.invalid:${origin.port}']);
      },
    );
    test(
      'manual HTTP uses only the proxy, with the destination hostname',
      () async {
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => proxy.close(force: true));
        Uri? forwarded;
        proxy.listen((request) async {
          forwarded = request.uri;
          request.response.write('proxied');
          await request.response.close();
        });
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.http, port: proxy.port),
        );
        addTearDown(service.dispose);
        final response = await service.get(
          Uri.parse('http://never-resolve.invalid/image?q=test'),
          retry: false,
        );
        expect(response.body, 'proxied');
        expect(
          forwarded.toString(),
          'http://never-resolve.invalid/image?q=test',
        );
      },
    );

    test('failed proxy never falls back to a reachable origin', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var originHits = 0;
      origin.listen((request) {
        originHits++;
        request.response.close();
      });
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();
      for (final mode in [NetworkMode.http, NetworkMode.socks5]) {
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: mode, port: port),
        );
        await expectLater(
          service.get(
            Uri.parse('http://127.0.0.1:${origin.port}/'),
            retry: false,
          ),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.kind,
              'kind',
              NetworkErrorKind.proxy,
            ),
          ),
        );
        service.dispose();
      }
      expect(originHits, 0);
    });

    test(
      'SOCKS5 negotiates fragmented frames and resolves host at proxy',
      () async {
        final proxy = await _SocksProxy.start(fragmented: true);
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        addTearDown(service.dispose);
        final response = await service.get(
          Uri.parse('http://never-resolve.invalid:8088/image'),
          retry: false,
        );
        expect(response.body, 'socks image');
        expect(proxy.targets, ['never-resolve.invalid:8088']);
        expect(proxy.addressTypes, [3]);
      },
    );

    test('SOCKS5 supports IPv4 and IPv6 targets without DNS', () async {
      final proxy = await _SocksProxy.start();
      addTearDown(proxy.close);
      final service = AppNetworkService.forTesting(
        settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
      );
      addTearDown(service.dispose);
      expect(
        (await service.get(
          Uri.parse('http://192.0.2.1:8088/'),
          retry: false,
        )).statusCode,
        200,
      );
      expect(
        (await service.get(
          Uri.parse('http://[2001:db8::1]:8089/'),
          retry: false,
        )).statusCode,
        200,
      );
      expect(proxy.addressTypes, [1, 4]);
    });

    test('SOCKS5 authentication refusal fails closed', () async {
      for (final method in [2, 255]) {
        final proxy = await _SocksProxy.start(method: method);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        await expectLater(
          service.get(Uri.parse('http://never-resolve.invalid/'), retry: false),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.kind,
              'kind',
              NetworkErrorKind.proxy,
            ),
          ),
        );
        expect(proxy.targets, isEmpty);
        service.dispose();
        await proxy.close();
      }
    });

    test('cancellation closes a stalled SOCKS handshake', () async {
      final proxy = await _SocksProxy.start(stallGreeting: true);
      addTearDown(proxy.close);
      final service = AppNetworkService.forTesting(
        settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
      );
      addTearDown(service.dispose);
      final token = NetworkCancelToken();
      final request = service.get(
        Uri.parse('https://never-resolve.invalid/'),
        cancelToken: token,
        retry: false,
      );
      final result = expectLater(
        request,
        throwsA(isA<NetworkCancelledException>()),
      );
      await proxy.entered.future.timeout(const Duration(seconds: 2));
      token.cancel();
      await result;
      await proxy.disconnected.future.timeout(const Duration(seconds: 2));
    });

    test('deadline closes a stalled SOCKS handshake', () async {
      final proxy = await _SocksProxy.start(stallGreeting: true);
      addTearDown(proxy.close);
      final service = AppNetworkService.forTesting(
        settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.get(
          Uri.parse('https://never-resolve.invalid/'),
          timeout: const Duration(milliseconds: 150),
          retry: false,
        ),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.kind,
            'kind',
            NetworkErrorKind.timeout,
          ),
        ),
      );
      await proxy.disconnected.future.timeout(const Duration(seconds: 2));
    });

    test(
      'cancellation closes TCP even while TLS handshake is stalled',
      () async {
        final proxy = await _SocksProxy.start(stallTls: true);
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        addTearDown(service.dispose);
        final token = NetworkCancelToken();
        final result = expectLater(
          service.get(
            Uri.parse('https://never-resolve.invalid/'),
            cancelToken: token,
            retry: false,
          ),
          throwsA(isA<NetworkCancelledException>()),
        );
        await proxy.tlsStarted.future.timeout(const Duration(seconds: 2));
        token.cancel();
        await result;
        await proxy.disconnected.future.timeout(const Duration(seconds: 2));
      },
    );

    test(
      'SOCKS5 HTTPS verifies the destination certificate and transfers data',
      () async {
        final serverContext = SecurityContext()
          ..useCertificateChain('test/fixtures/network/localhost-cert.pem')
          ..usePrivateKey('test/fixtures/network/localhost-key.pem');
        final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverContext,
        );
        addTearDown(() => origin.close(force: true));
        origin.listen((request) async {
          if (request.uri.path == '/redirect') {
            request.response.statusCode = 302;
            request.response.contentLength = 0;
            request.response.headers.set(HttpHeaders.locationHeader, '/image');
          } else {
            request.response.write('verified encrypted image');
          }
          await request.response.close();
        }, onError: (Object _) {});
        final proxy = await _SocksProxy.start(forwardPort: origin.port);
        addTearDown(proxy.close);
        final trustedContext = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('test/fixtures/network/localhost-cert.pem');
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
          clientFactory: (settings) => createNetworkClientForTesting(
            settings,
            securityContext: trustedContext,
          ),
        );
        addTearDown(service.dispose);
        final response = await service.get(
          Uri.parse('https://never-resolve.invalid:${origin.port}/redirect'),
          retry: false,
        );
        expect(response.body, 'verified encrypted image');
        expect(proxy.targets, ['never-resolve.invalid:${origin.port}']);
        // Trusting an issuer does not remove target host verification.
        await expectLater(
          service.get(
            Uri.parse('https://wrong-host.invalid:${origin.port}/image'),
            retry: false,
          ),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.kind,
              'kind',
              NetworkErrorKind.tls,
            ),
          ),
        );
      },
    );

    test(
      'SOCKS5 HTTPS rejects an untrusted certificate without fallback',
      () async {
        final serverContext = SecurityContext()
          ..useCertificateChain('test/fixtures/network/localhost-cert.pem')
          ..usePrivateKey('test/fixtures/network/localhost-key.pem');
        final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverContext,
        );
        addTearDown(() => origin.close(force: true));
        var requests = 0;
        origin.listen((request) {
          requests++;
          request.response.close();
        }, onError: (Object _) {});
        final proxy = await _SocksProxy.start(forwardPort: origin.port);
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.socks5, port: proxy.port),
        );
        addTearDown(service.dispose);
        await expectLater(
          service.get(
            Uri.parse('https://never-resolve.invalid:${origin.port}/image'),
            retry: false,
          ),
          throwsA(
            isA<NetworkException>().having(
              (e) => e.kind,
              'kind',
              NetworkErrorKind.tls,
            ),
          ),
        );
        expect(requests, 0);
      },
    );
  });
}

class _SocksProxy {
  _SocksProxy(
    this.server,
    this.fragmented,
    this.method,
    this.stallGreeting,
    this.stallTls,
    this.forwardPort,
  ) {
    server.listen((socket) {
      sockets.add(socket);
      unawaited(
        _serve(socket).catchError((Object _) {}).whenComplete(() {
          sockets.remove(socket);
          socket.destroy();
          if (!disconnected.isCompleted) disconnected.complete();
        }),
      );
    });
  }

  static Future<_SocksProxy> start({
    bool fragmented = false,
    int method = 0,
    bool stallGreeting = false,
    bool stallTls = false,
    int? forwardPort,
  }) async => _SocksProxy(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    fragmented,
    method,
    stallGreeting,
    stallTls,
    forwardPort,
  );

  final ServerSocket server;
  final bool fragmented;
  final int method;
  final bool stallGreeting;
  final bool stallTls;
  final int? forwardPort;
  final Set<Socket> sockets = {};
  final List<String> targets = [];
  final List<int> addressTypes = [];
  final entered = Completer<void>();
  final tlsStarted = Completer<void>();
  final disconnected = Completer<void>();
  int get port => server.port;

  Future<void> _send(Socket socket, List<int> data) async {
    for (final part in fragmented ? data.map((byte) => [byte]) : [data]) {
      socket.add(part);
      await socket.flush();
      if (fragmented) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  Future<void> _serve(Socket socket) async {
    final reader = _Reader(socket);
    expect(await reader.read(3), [5, 1, 0]);
    if (!entered.isCompleted) entered.complete();
    if (stallGreeting) {
      await reader.drain();
      return;
    }
    await _send(socket, [5, method]);
    if (method != 0) return;
    final header = await reader.read(4);
    expect(header.sublist(0, 3), [5, 1, 0]);
    addressTypes.add(header[3]);
    String host;
    if (header[3] == 3) {
      host = ascii.decode(await reader.read((await reader.read(1)).single));
    } else {
      final bytes = await reader.read(header[3] == 1 ? 4 : 16);
      host = InternetAddress.fromRawAddress(Uint8List.fromList(bytes)).address;
    }
    final port = await reader.read(2);
    targets.add('$host:${port[0] * 256 + port[1]}');
    await _send(socket, [5, 0, 0, 1, 127, 0, 0, 1, 0, 80]);
    if (forwardPort case final port?) {
      final upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
      try {
        await Future.wait([
          upstream.addStream(reader.remainder()).then((_) => upstream.close()),
          socket.addStream(upstream).then((_) => socket.close()),
        ]);
      } finally {
        upstream.destroy();
      }
      return;
    }
    if (stallTls) {
      await reader.read(1);
      if (!tlsStarted.isCompleted) tlsStarted.complete();
      await reader.drain();
      return;
    }
    final request = <int>[];
    while (!ascii.decode(request).endsWith('\r\n\r\n')) {
      request.addAll(await reader.read(1));
    }
    socket.add(
      ascii.encode(
        'HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nsocks image',
      ),
    );
    await socket.flush();
  }

  Future<void> close() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await server.close();
  }
}

class _Reader {
  _Reader(Socket socket) : iterator = StreamIterator(socket);
  final StreamIterator<List<int>> iterator;
  List<int> current = [];
  int offset = 0;

  Future<List<int>> read(int length) async {
    final result = <int>[];
    while (result.length < length) {
      if (offset == current.length) {
        if (!await iterator.moveNext()) throw const SocketException('closed');
        current = iterator.current;
        offset = 0;
      }
      final count = (length - result.length).clamp(0, current.length - offset);
      result.addAll(current.sublist(offset, offset + count));
      offset += count;
    }
    return result;
  }

  Future<void> drain() async {
    while (await iterator.moveNext()) {}
  }

  Stream<List<int>> remainder() async* {
    if (offset < current.length) yield current.sublist(offset);
    while (await iterator.moveNext()) {
      yield iterator.current;
    }
  }
}
