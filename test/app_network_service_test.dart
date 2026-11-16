import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:danbooru_viewer/favorites_manager.dart';
import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/failing_preferences_store.dart';
import 'support/native_memory_preferences_store.dart';

class _OneFailedCommitStore extends NativeMemoryPreferencesStore {
  _OneFailedCommitStore(super.initialValues);

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    try {
      return await super.setValue(valueType, key, value);
    } finally {
      // Only the original commit fails; an explicit rollback can succeed.
      failures.remove(key.substring('flutter.'.length));
    }
  }
}

void main() {
  group('bounded request policy', () {
    test(
      'closing a client during request finalization prevents sending',
      () async {
        var sends = 0;
        final service = AppNetworkService.forTesting(
          clientFactory: (_) => MockClient((_) async {
            sends++;
            return http.Response('unexpected', 200);
          }),
        );
        addTearDown(service.dispose);
        final client = service.createClient();
        final request = http.StreamedRequest(
          'GET',
          Uri.parse('https://example.test/'),
        );
        final failed = expectLater(
          client.send(request),
          throwsA(isA<NetworkCancelledException>()),
        );
        client.close();
        await request.sink.close();
        await failed;
        expect(sends, 0);
      },
    );

    test('connection probe completes after a bounded response body', () async {
      final service = AppNetworkService.forTesting(
        clientFactory: (_) =>
            MockClient((_) async => http.Response('sample', 200)),
      );
      addTearDown(service.dispose);
      expect(
        (await service.probe(Uri.parse('https://example.test/'))).succeeded,
        isTrue,
      );
    });
    test(
      '429 Retry-After is respected; final response is returned after bounded retries',
      () async {
        var requests = 0;
        final times = <DateTime>[];
        final service = AppNetworkService.forTesting(
          retryDelay: const Duration(milliseconds: 2),
          clientFactory: (_) => MockClient((_) async {
            times.add(DateTime.now());
            requests++;
            return http.Response(
              'slow down',
              429,
              headers: {'retry-after': requests == 1 ? '1' : '0'},
            );
          }),
        );
        addTearDown(service.dispose);
        expect(
          (await service.get(Uri.parse('https://example.test/'))).statusCode,
          429,
        );
        expect(requests, 3);
        expect(
          times[1].difference(times[0]),
          greaterThanOrEqualTo(const Duration(milliseconds: 950)),
        );
      },
    );

    test(
      'large Retry-After does not retry earlier than server permits',
      () async {
        var requests = 0;
        final service = AppNetworkService.forTesting(
          clientFactory: (_) => MockClient((_) async {
            requests++;
            return http.Response('busy', 503, headers: {'retry-after': '120'});
          }),
        );
        addTearDown(service.dispose);
        expect(
          (await service.get(Uri.parse('https://example.test/'))).statusCode,
          503,
        );
        expect(requests, 1);
      },
    );

    test('server errors recover, access denial is not retried', () async {
      var requests = 0;
      final service = AppNetworkService.forTesting(
        retryDelay: Duration.zero,
        clientFactory: (_) => MockClient((uri) async {
          requests++;
          return http.Response(
            'response',
            uri.url.path == '/denied'
                ? 403
                : requests == 1
                ? 503
                : 200,
          );
        }),
      );
      addTearDown(service.dispose);
      expect(
        (await service.get(
          Uri.parse('https://example.test/recover'),
        )).statusCode,
        200,
      );
      expect(requests, 2);
      expect(
        (await service.get(
          Uri.parse('https://example.test/denied'),
        )).statusCode,
        403,
      );
      expect(requests, 3);
    });

    test('parses Retry-After HTTP-date and rejects invalid delay', () {
      final now = DateTime.utc(2026, 1, 1);
      expect(
        retryAfterDelay('Thu, 01 Jan 2026 00:00:04 GMT', now: now),
        const Duration(seconds: 4),
      );
      expect(
        retryAfterDelay('Wed, 31 Dec 2025 23:59:00 GMT', now: now),
        Duration.zero,
      );
      expect(retryAfterDelay('-1'), isNull);
      expect(retryAfterDelay('invalid'), isNull);
    });

    test('stream cancellation closes the actual TCP connection', () async {
      final server = await _HangingServer.start();
      addTearDown(server.close);
      final service = AppNetworkService.forTesting(
        settings: const NetworkSettings(mode: NetworkMode.direct),
      );
      addTearDown(service.dispose);
      final response = await service.stream(server.uri);
      final first = Completer<void>();
      final subscription = response.stream.listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await subscription.cancel();
      await server.disconnected.future.timeout(const Duration(seconds: 2));
    });

    test(
      'token cancels a body download without cancelling another request',
      () async {
        final server = await _HangingServer.start();
        addTearDown(server.close);
        final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => other.close(force: true));
        other.listen((request) {
          request.response.write('ok');
          request.response.close();
        });
        final service = AppNetworkService.forTesting(
          settings: const NetworkSettings(mode: NetworkMode.direct),
        );
        addTearDown(service.dispose);
        final token = NetworkCancelToken();
        final cancelled = expectLater(
          service.get(server.uri, cancelToken: token),
          throwsA(isA<NetworkCancelledException>()),
        );
        await server.entered.future;
        final otherRequest = service.get(
          Uri.parse('http://127.0.0.1:${other.port}/'),
        );
        token.cancel();
        await cancelled;
        expect((await otherRequest).body, 'ok');
        await server.disconnected.future.timeout(const Duration(seconds: 2));
      },
    );

    test('deadline covers the response body and closes the socket', () async {
      final server = await _HangingServer.start();
      addTearDown(server.close);
      final service = AppNetworkService.forTesting(
        settings: const NetworkSettings(mode: NetworkMode.direct),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.get(server.uri, timeout: const Duration(milliseconds: 100)),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.kind,
            'kind',
            NetworkErrorKind.timeout,
          ),
        ),
      );
      await server.disconnected.future.timeout(const Duration(seconds: 2));
    });

    test(
      'setting changes cancel old requests and immediately use the new route',
      () async {
        final oldProxy = await _HangingServer.start(sendHeaders: false);
        addTearDown(oldProxy.close);
        final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => proxy.close(force: true));
        proxy.listen((request) {
          request.response.write('new proxy');
          request.response.close();
        });
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(
            mode: NetworkMode.http,
            port: oldProxy.port,
          ),
        );
        addTearDown(service.dispose);
        var notifications = 0;
        service.addListener(() => notifications++);
        final target = Uri.parse('http://never-resolve.invalid/image');
        final oldRequest = expectLater(
          service.get(target),
          throwsA(isA<NetworkCancelledException>()),
        );
        await oldProxy.entered.future;
        await service.updateSettings(
          NetworkSettings(mode: NetworkMode.http, port: proxy.port),
        );
        await oldRequest;
        expect((await service.get(target)).body, 'new proxy');
        expect(service.revision, 1);
        expect(notifications, 1);
        await oldProxy.disconnected.future.timeout(const Duration(seconds: 2));
      },
    );

    test(
      'cache client uses the same proxy and closing it cancels downloads',
      () async {
        final proxy = await _HangingServer.start();
        addTearDown(proxy.close);
        final service = AppNetworkService.forTesting(
          settings: NetworkSettings(mode: NetworkMode.http, port: proxy.port),
        );
        addTearDown(service.dispose);
        final client = service.createClient();
        final request = expectLater(
          client.get(Uri.parse('http://never-resolve.invalid/media')),
          throwsA(isA<NetworkCancelledException>()),
        );
        await proxy.entered.future;
        client.close();
        await request;
        await proxy.disconnected.future.timeout(const Duration(seconds: 2));
      },
    );
  });

  group('persisted settings fail closed', () {
    for (final failure in PreferenceFailure.values) {
      test('acknowledged rollback retains the old route: $failure', () async {
        const original = NetworkSettings(mode: NetworkMode.socks5, port: 9050);
        final encoded = jsonEncode(original.toJson());
        final backend = _OneFailedCommitStore({
          AppNetworkService.settingsKey: encoded,
        });
        final preferences = await backend.install();
        addTearDown(() => SharedPreferences.setMockInitialValues({}));
        final service = AppNetworkService.forTesting(loadPreferences: true);
        addTearDown(service.dispose);
        await service.initialize();
        backend.failures[AppNetworkService.settingsKey] = failure;
        await expectLater(
          service.updateSettings(
            const NetworkSettings(mode: NetworkMode.direct),
          ),
          throwsStateError,
        );
        expect(service.settings, original);
        expect(service.revision, 0);
        expect(service.configurationLoadError, isNull);
        expect(preferences.getString(AppNetworkService.settingsKey), encoded);
        expect(backend.persisted[AppNetworkService.settingsKey], encoded);
        expect(backend.nativeMemory[AppNetworkService.settingsKey], encoded);
        expect(backend.attemptedWrites, [
          AppNetworkService.settingsKey,
          AppNetworkService.settingsKey,
        ]);
      });

      test(
        'unconfirmed native writes block reopened routes: $failure',
        () async {
          const original = NetworkSettings(
            mode: NetworkMode.socks5,
            port: 9050,
          );
          const attempted = NetworkSettings(mode: NetworkMode.direct);
          final encoded = jsonEncode(original.toJson());
          final backend = NativeMemoryPreferencesStore({
            AppNetworkService.settingsKey: encoded,
          })..heldKey = AppNetworkService.settingsKey;
          await backend.install();
          addTearDown(() {
            backend.release();
            SharedPreferences.setMockInitialValues({});
          });
          final routes = <NetworkSettings>[];
          http.Client factory(NetworkSettings settings) =>
              MockClient((_) async {
                routes.add(settings);
                return http.Response('ok', 200);
              });
          final service = AppNetworkService.forTesting(
            loadPreferences: true,
            clientFactory: factory,
          );
          addTearDown(service.dispose);
          await service.initialize();
          backend.failures[AppNetworkService.settingsKey] = failure;
          final rejected = expectLater(
            service.updateSettings(attempted),
            throwsStateError,
          );
          await backend.started.future;
          expect(
            backend.nativeMemory[AppNetworkService.settingsKey],
            jsonEncode(attempted.toJson()),
          );
          expect(backend.persisted[AppNetworkService.settingsKey], encoded);

          final reopened = AppNetworkService.forTesting(
            loadPreferences: true,
            clientFactory: factory,
          );
          addTearDown(reopened.dispose);
          var initialized = false;
          final initialization = reopened.initialize().then((_) {
            initialized = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(initialized, isFalse);
          backend.release();
          await rejected;
          await initialization;
          for (final candidate in [service, reopened]) {
            expect(candidate.settings, original);
            expect(candidate.revision, 0);
            expect(candidate.configurationLoadError, isNotNull);
            await expectLater(
              candidate.get(Uri.parse('https://example.test/')),
              throwsA(isA<NetworkException>()),
            );
          }
          expect(routes, isEmpty);

          backend.failures.clear();
          await service.updateSettings(original);
          expect(service.configurationLoadError, isNull);
          expect(service.revision, 1);
          await service.get(Uri.parse('https://example.test/'));
          expect(routes, [original]);
          expect(backend.persisted[AppNetworkService.settingsKey], encoded);
        },
      );
    }

    test(
      'failed write and rollback block traffic until a successful save',
      () async {
        final backend = FailingPreferencesStore();
        await backend.install();
        addTearDown(() => SharedPreferences.setMockInitialValues({}));
        var requests = 0;
        final service = AppNetworkService.forTesting(
          loadPreferences: true,
          clientFactory: (_) => MockClient((_) async {
            requests++;
            return http.Response('ok', 200);
          }),
        );
        addTearDown(service.dispose);
        await service.initialize();
        backend.setFailures[AppNetworkService.settingsKey] =
            PreferenceFailure.returnFalse;
        backend.removeFailures[AppNetworkService.settingsKey] =
            PreferenceFailure.returnFalse;
        await expectLater(
          service.updateSettings(
            const NetworkSettings(mode: NetworkMode.direct),
          ),
          throwsStateError,
        );
        expect(service.configurationLoadError, isNotNull);
        await expectLater(
          service.get(Uri.parse('https://example.test/')),
          throwsA(isA<NetworkException>()),
        );
        expect(requests, 0);
        backend.removeFailures.clear();
        backend.setFailures.clear();
        await service.updateSettings(const NetworkSettings());
        expect(service.configurationLoadError, isNull);
        expect(
          (await service.get(Uri.parse('https://example.test/'))).statusCode,
          200,
        );
      },
    );

    test('another store cannot commit an unconfirmed network value', () async {
      const original = NetworkSettings(mode: NetworkMode.socks5, port: 9050);
      final encoded = jsonEncode(original.toJson());
      final backend = NativeMemoryPreferencesStore({
        AppNetworkService.settingsKey: encoded,
        'favorite_posts_full': '[]',
        'favorite_posts': '[]',
      });
      final preferences = await backend.install();
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final service = AppNetworkService.forTesting(loadPreferences: true);
      addTearDown(service.dispose);
      await service.initialize();
      backend.failures[AppNetworkService.settingsKey] =
          PreferenceFailure.returnFalse;
      await expectLater(
        service.updateSettings(const NetworkSettings(mode: NetworkMode.direct)),
        throwsStateError,
      );
      final favorites = FavoritesManager.forTesting(preferences);
      await expectLater(favorites.toggleFavorite({'id': 1}), throwsStateError);
      expect(backend.attemptedWrites.toSet(), {AppNetworkService.settingsKey});
      expect(backend.persisted['favorite_posts_full'], '[]');
      expect(backend.persisted[AppNetworkService.settingsKey], encoded);

      backend.failures.clear();
      expect(await favorites.toggleFavorite({'id': 1}), isTrue);
      expect(backend.persisted[AppNetworkService.settingsKey], encoded);
      expect(jsonDecode(backend.persisted['favorite_posts_full']! as String), [
        {'id': 1},
      ]);
    });

    test('an unrelated recovery never invalidates a confirmed route', () async {
      const original = NetworkSettings(mode: NetworkMode.socks5, port: 9050);
      final encoded = jsonEncode(original.toJson());
      final backend = NativeMemoryPreferencesStore({
        AppNetworkService.settingsKey: encoded,
        'favorite_posts_full': '[]',
        'favorite_posts': '[]',
      });
      final preferences = await backend.install();
      addTearDown(() => SharedPreferences.setMockInitialValues({}));
      final favorites = FavoritesManager.forTesting(preferences);
      backend.failures['favorite_posts_full'] = PreferenceFailure.returnFalse;
      await expectLater(favorites.toggleFavorite({'id': 1}), throwsStateError);
      final routes = <NetworkSettings>[];
      final service = AppNetworkService.forTesting(
        loadPreferences: true,
        clientFactory: (settings) => MockClient((_) async {
          routes.add(settings);
          return http.Response('ok', 200);
        }),
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.configurationLoadError, isNull);
      await expectLater(
        service.updateSettings(const NetworkSettings(mode: NetworkMode.direct)),
        throwsStateError,
      );
      expect(service.settings, original);
      expect(service.configurationLoadError, isNull);
      await service.get(Uri.parse('https://example.test/'));
      expect(routes, [original]);
      expect(backend.persisted[AppNetworkService.settingsKey], encoded);
      expect(backend.attemptedWrites.toSet(), {'favorite_posts_full'});
    });

    test('saves only endpoint information and restores it', () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppNetworkService.forTesting(loadPreferences: true);
      await service.initialize();
      await service.updateSettings(
        const NetworkSettings(
          mode: NetworkMode.socks5,
          host: 'localhost',
          port: 9050,
        ),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        jsonDecode(preferences.getString(AppNetworkService.settingsKey)!),
        {'mode': 'socks5', 'host': 'localhost', 'port': 9050},
      );
      final restored = AppNetworkService.forTesting(loadPreferences: true);
      await restored.initialize();
      expect(restored.settings, service.settings);
      restored.dispose();
      service.dispose();
    });

    for (final stored in [
      '{broken',
      123,
      '{"mode":"http","host":"bad host","port":10808}',
    ]) {
      test(
        'corrupt preference is blocked until explicit save: $stored',
        () async {
          SharedPreferences.setMockInitialValues({
            AppNetworkService.settingsKey: stored,
          });
          var requests = 0;
          final service = AppNetworkService.forTesting(
            loadPreferences: true,
            clientFactory: (_) => MockClient((_) async {
              requests++;
              return http.Response('ok', 200);
            }),
          );
          addTearDown(service.dispose);
          await service.initialize();
          expect(service.configurationLoadError, isNotNull);
          await expectLater(
            service.get(Uri.parse('https://example.test/')),
            throwsA(isA<NetworkException>()),
          );
          expect(requests, 0);
          await service.updateSettings(const NetworkSettings());
          expect(service.configurationLoadError, isNull);
          expect(service.revision, 1);
          expect(
            (await service.get(Uri.parse('https://example.test/'))).statusCode,
            200,
          );
        },
      );
    }

    test(
      'unavailable preferences do not crash initialization or send traffic',
      () async {
        final service = AppNetworkService.forTesting(
          loadPreferences: true,
          preferencesLoader: () => Future<SharedPreferences>.error(
            StateError('storage unavailable'),
          ),
        );
        addTearDown(service.dispose);
        await service.initialize();
        expect(service.configurationLoadError, isNotNull);
        await expectLater(
          service.get(Uri.parse('https://example.test/')),
          throwsA(isA<NetworkException>()),
        );
        await expectLater(
          service.updateSettings(const NetworkSettings()),
          throwsStateError,
        );
        expect(service.configurationLoadError, isNotNull);
      },
    );
  });
}

class _HangingServer {
  _HangingServer(this.server, this.sendHeaders) {
    server.listen((socket) {
      sockets.add(socket);
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      var received = '';
      var responded = false;
      socket.listen(
        (data) {
          received += ascii.decode(data);
          if (!responded && received.contains('\r\n\r\n')) {
            responded = true;
            if (sendHeaders) {
              socket.add(
                ascii.encode(
                  'HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n\r\nx',
                ),
              );
            }
            if (!entered.isCompleted) entered.complete();
          }
        },
        onError: (Object _) {},
        onDone: () {
          sockets.remove(socket);
          socket.destroy();
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
  }

  static Future<_HangingServer> start({bool sendHeaders = true}) async =>
      _HangingServer(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        sendHeaders,
      );
  final ServerSocket server;
  final bool sendHeaders;
  final Set<Socket> sockets = {};
  final entered = Completer<void>();
  final disconnected = Completer<void>();
  int get port => server.port;
  Uri get uri => Uri.parse('http://127.0.0.1:$port/media');

  Future<void> close() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await server.close();
  }
}
