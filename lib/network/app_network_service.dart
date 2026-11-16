import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/reliable_preferences.dart';
import 'network_errors.dart';
import 'network_settings.dart';
import 'network_transport_io.dart'
    if (dart.library.js_interop) 'network_transport_web.dart'
    as transport;

export 'network_errors.dart';
export 'network_settings.dart';

typedef NetworkClientFactory = http.Client Function(NetworkSettings settings);

class NetworkProbeResult {
  const NetworkProbeResult({
    required this.host,
    required this.elapsed,
    required this.succeeded,
    this.statusCode,
    this.message,
  });

  final String host;
  final Duration elapsed;
  final bool succeeded;
  final int? statusCode;
  final String? message;
}

/// All application HTTP traffic goes through one policy. Each operation owns
/// its client, allowing real cancellation without killing unrelated requests.
class AppNetworkService extends ChangeNotifier {
  AppNetworkService._()
    : _clientFactory = transport.createNetworkClient,
      _preferencesLoader = SharedPreferences.getInstance,
      _persistSettings = true;

  @visibleForTesting
  AppNetworkService.forTesting({
    NetworkSettings settings = const NetworkSettings(),
    NetworkClientFactory? clientFactory,
    bool loadPreferences = false,
    Future<SharedPreferences> Function()? preferencesLoader,
    this.retryDelay = const Duration(milliseconds: 500),
    this.maxAttempts = 3,
  }) : _settings = settings,
       _clientFactory = clientFactory ?? transport.createNetworkClient,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _persistSettings = loadPreferences,
       _initialized = !loadPreferences;

  static final AppNetworkService instance = AppNetworkService._();
  static const settingsKey = 'network_settings_v1';
  static const apiTimeout = Duration(seconds: 25);
  static const mediaTimeout = Duration(minutes: 3);
  static const maxRetryDelay = Duration(seconds: 30);
  static const maxApiResponseBytes = 16 * 1024 * 1024;

  final NetworkClientFactory _clientFactory;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final bool _persistSettings;
  Duration retryDelay = const Duration(milliseconds: 500);
  int maxAttempts = 3;
  NetworkSettings _settings = const NetworkSettings();
  NetworkSettings get settings => _settings;
  NetworkException? _configurationLoadError;
  NetworkException? get configurationLoadError => _configurationLoadError;
  int _revision = 0;
  int get revision => _revision;
  bool _initialized = false;
  Future<void>? _initialization;
  Future<void> _settingsQueue = Future<void>.value();
  final Set<_ActiveRequest> _active = {};
  bool _disposed = false;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initialization ??= _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final preferences = ReliablePreferences.forInstance(
        await _preferencesLoader(),
      );
      final encoded = (await preferences.readAll())[settingsKey];
      if (encoded != null) {
        _settings = NetworkSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(encoded as String) as Map),
        );
      }
      if (preferences.recoveryKeys.contains(settingsKey)) {
        throw StateError('网络配置尚未确认恢复。');
      }
    } on Object {
      // Keep settings accessible, but do not silently replace a saved proxy
      // with a potentially direct route when storage is damaged/unavailable.
      _configurationLoadError = const NetworkException(
        NetworkErrorKind.proxy,
        '无法读取已保存的网络配置。请打开网络设置，确认并重新保存后再连接。',
      );
    }
    _initialized = true;
  }

  Future<void> updateSettings(NetworkSettings settings) {
    final next = _settingsQueue.then((_) async {
      await initialize();
      if (_disposed) throw const NetworkCancelledException();
      final error = settings.validate();
      if (error != null) {
        throw NetworkException(NetworkErrorKind.proxy, error);
      }
      final preferences = _persistSettings
          ? ReliablePreferences.forInstance(await _preferencesLoader())
          : null;
      if (settings == _settings &&
          _configurationLoadError == null &&
          preferences?.recoveryRequired != true) {
        return;
      }
      if (preferences != null) {
        try {
          await preferences.setString(
            settingsKey,
            jsonEncode(settings.toJson()),
          );
        } catch (error, stack) {
          // A successful platform reload can still return an uncommitted
          // native value. Only the shared recovery guard can confirm rollback.
          if (preferences.recoveryKeys.contains(settingsKey)) {
            _configurationLoadError = const NetworkException(
              NetworkErrorKind.proxy,
              '网络配置保存失败，且尚未确认恢复。请确认并重新保存后再连接。',
            );
            for (final request in _active.toList()) {
              request.abort(_configurationLoadError!);
            }
          }
          Error.throwWithStackTrace(error, stack);
        }
      }
      _settings = settings;
      _configurationLoadError = null;
      for (final request in _active.toList()) {
        request.abort(const NetworkCancelledException('网络设置已更改，请重新加载。'));
      }
      // Cache downloads isolate their in-flight subjects by this revision.
      // A paused disk sink may delay its old error indefinitely; notification
      // must not depend on an arbitrary event-loop delay or that sink resuming.
      if (_disposed) throw const NetworkCancelledException();
      _revision++;
      notifyListeners();
    });
    _settingsQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<http.Response> get(
    Uri uri, {
    NetworkCancelToken? cancelToken,
    Duration? timeout,
    bool retry = true,
    Map<String, String>? headers,
  }) async {
    final response = await stream(
      uri,
      cancelToken: cancelToken,
      timeout: timeout ?? apiTimeout,
      retry: retry,
      headers: headers,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxApiResponseBytes) {
        throw const NetworkException(
          NetworkErrorKind.invalidResponse,
          '服务器响应过大，请缩小查询范围后重试。',
        );
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      headers: response.headers,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  Future<http.StreamedResponse> stream(
    Uri uri, {
    NetworkCancelToken? cancelToken,
    Duration? timeout,
    bool retry = true,
    Map<String, String>? headers,
  }) async {
    await initialize();
    if (_disposed) throw const NetworkCancelledException();
    if (_configurationLoadError case final error?) throw error;
    cancelToken?.throwIfCancelled();
    validateNetworkUri(uri);
    final settings = _settings;
    final operation = _ActiveRequest(
      timeout ?? mediaTimeout,
      cancelToken,
      () {},
    );
    operation.onFinish = () => _active.remove(operation);
    _active.add(operation);
    try {
      for (var attempt = 0; ; attempt++) {
        operation.throwIfAborted();
        final client = _clientFactory(settings);
        operation.client = client;
        try {
          final request = http.AbortableRequest(
            'GET',
            uri,
            abortTrigger: operation.aborted.future,
          );
          request.headers.addAll(headers ?? const {});
          final response = await operation.race(client.send(request));
          final canRetry = retry && attempt + 1 < maxAttempts;
          final retryStatus = {
            429,
            500,
            502,
            503,
            504,
          }.contains(response.statusCode);
          final delay =
              retryAfterDelay(response.headers['retry-after']) ??
              retryDelay * (1 << attempt);
          if (canRetry &&
              retryStatus &&
              delay <= maxRetryDelay &&
              delay < operation.remaining) {
            // Closing, rather than draining, bounds a malicious/stalled error
            // body and releases the connection before waiting to retry.
            await response.stream.listen(null).cancel();
            client.close();
            operation.client = null;
            await operation.race(Future<void>.delayed(delay));
            continue;
          }
          return http.StreamedResponse(
            _managedBody(response.stream, operation, settings),
            response.statusCode,
            headers: response.headers,
            contentLength: response.contentLength,
            request: response.request,
            isRedirect: response.isRedirect,
            persistentConnection: response.persistentConnection,
            reasonPhrase: response.reasonPhrase,
          );
        } catch (error) {
          operation.throwIfAborted();
          final classified = _classify(error, settings);
          client.close();
          operation.client = null;
          final delay = retryDelay * (1 << attempt);
          if (retry &&
              attempt + 1 < maxAttempts &&
              classified.kind == NetworkErrorKind.connection &&
              delay < operation.remaining) {
            await operation.race(Future<void>.delayed(delay));
            continue;
          }
          throw classified;
        }
      }
    } catch (_) {
      operation.finish();
      rethrow;
    }
  }

  Stream<List<int>> _managedBody(
    Stream<List<int>> source,
    _ActiveRequest operation,
    NetworkSettings settings,
  ) {
    StreamSubscription<List<int>>? subscription;
    late StreamController<List<int>> controller;
    void fail(NetworkException error) {
      if (controller.isClosed) return;
      controller.addError(error);
      unawaited(controller.close());
      unawaited(subscription?.cancel());
      operation.finish();
    }

    controller = StreamController<List<int>>(
      onListen: () {
        if (operation.abortReason case final reason?) {
          fail(reason);
          return;
        }
        unawaited(
          operation.aborted.future.then((_) {
            fail(operation.abortReason ?? const NetworkCancelledException());
          }),
        );
        subscription = source.listen(
          controller.add,
          onError: (Object error, StackTrace stack) =>
              fail(operation.abortReason ?? _classify(error, settings)),
          onDone: () {
            // The source has already completed. Cancelling it again can wait
            // on its own completion callback and delay the consumer's done.
            subscription = null;
            operation.finish();
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        final sourceSubscription = subscription;
        subscription = null;
        operation.finish();
        await sourceSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  http.Client createClient() => _PolicyClient(this);

  Future<NetworkProbeResult> probe(
    Uri uri, {
    NetworkCancelToken? cancelToken,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final response = await stream(
        uri,
        cancelToken: cancelToken,
        timeout: const Duration(seconds: 15),
        retry: false,
        headers: const {'Range': 'bytes=0-1023'},
      );
      var read = 0;
      await for (final bytes in response.stream) {
        read += bytes.length;
        if (read >= 1024) break;
      }
      final succeeded =
          response.statusCode == 200 || response.statusCode == 206;
      return NetworkProbeResult(
        host: uri.host,
        elapsed: watch.elapsed,
        succeeded: succeeded,
        statusCode: response.statusCode,
        message: succeeded ? null : '服务器返回 HTTP ${response.statusCode}。',
      );
    } catch (error) {
      return NetworkProbeResult(
        host: uri.host,
        elapsed: watch.elapsed,
        succeeded: false,
        message: networkErrorMessage(error),
      );
    }
  }

  NetworkException _classify(Object error, NetworkSettings settings) {
    if (error is NetworkException) return error;
    if (error is http.RequestAbortedException) {
      return const NetworkCancelledException();
    }
    if (error is TimeoutException) {
      return const NetworkException(
        NetworkErrorKind.timeout,
        '连接或下载超时，请检查网络和代理后重试。',
      );
    }
    return transport.classifyNetworkError(error, settings);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final request in _active.toList()) {
      request.abort(const NetworkCancelledException());
    }
    super.dispose();
  }
}

/// Parses delay-seconds and the HTTP-date format, without a dart:io dependency.
/// Large server delays are returned intact: callers decline to retry instead
/// of retrying earlier than Retry-After permits.
@visibleForTesting
Duration? retryAfterDelay(String? value, {DateTime? now}) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: seconds.clamp(0, 86400));
  }
  final match = RegExp(
    r'^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months.indexOf(match[2]!);
  if (month < 0) return null;
  final date = DateTime.utc(
    int.parse(match[3]!),
    month + 1,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
  final difference = date.difference((now ?? DateTime.now()).toUtc());
  return difference.isNegative ? Duration.zero : difference;
}

class _ActiveRequest {
  _ActiveRequest(Duration timeout, NetworkCancelToken? token, this.onFinish)
    : deadline = DateTime.now().add(timeout) {
    _timer = Timer(
      timeout,
      () => abort(
        const NetworkException(
          NetworkErrorKind.timeout,
          '连接或下载超时，请检查网络和代理后重试。',
        ),
      ),
    );
    _removeCancelListener = token?.addListener(
      () => abort(const NetworkCancelledException()),
    );
  }

  final DateTime deadline;
  Duration get remaining => deadline.difference(DateTime.now());
  final Completer<void> aborted = Completer<void>();
  NetworkException? abortReason;
  http.Client? client;
  late Timer _timer;
  void Function()? _removeCancelListener;
  void Function() onFinish;
  bool _finished = false;

  void abort(NetworkException reason) {
    if (_finished || abortReason != null) return;
    abortReason = reason;
    aborted.complete();
    client?.close();
    // A response may have been returned without its body being listened to.
    // Remove it from service bookkeeping even in that case.
    _timer.cancel();
    _removeCancelListener?.call();
    onFinish();
  }

  void throwIfAborted() {
    if (abortReason case final reason?) throw reason;
  }

  Future<T> race<T>(Future<T> future) => Future.any<T>([
    future,
    aborted.future.then<T>((_) => throw abortReason!),
  ]);

  void finish() {
    if (_finished) return;
    _finished = true;
    _timer.cancel();
    _removeCancelListener?.call();
    client?.close();
    onFinish();
  }
}

class _PolicyClient extends http.BaseClient {
  _PolicyClient(this.service);
  final AppNetworkService service;
  final Set<NetworkCancelToken> _tokens = {};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw const NetworkCancelledException();
    if (request.method != 'GET') {
      throw const NetworkException(
        NetworkErrorKind.invalidResponse,
        '媒体客户端只支持读取请求。',
      );
    }
    final body = await request.finalize().toBytes();
    if (_closed) throw const NetworkCancelledException();
    if (body.isNotEmpty) {
      throw const NetworkException(
        NetworkErrorKind.invalidResponse,
        '读取请求不能包含正文。',
      );
    }
    final token = NetworkCancelToken();
    _tokens.add(token);
    try {
      final response = await service.stream(
        request.url,
        cancelToken: token,
        headers: request.headers,
      );
      return http.StreamedResponse(
        _releaseOnDone(response.stream, token),
        response.statusCode,
        headers: response.headers,
        contentLength: response.contentLength,
        request: response.request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      _tokens.remove(token);
      rethrow;
    }
  }

  Stream<List<int>> _releaseOnDone(
    Stream<List<int>> source,
    NetworkCancelToken token,
  ) {
    StreamSubscription<List<int>>? subscription;
    late StreamController<List<int>> controller;
    void release() {
      _tokens.remove(token);
      token.cancel();
    }

    // Unlike async*, onCancel runs even when a subscriber cancels immediately
    // after listen(), before an asynchronous generator body could enter try.
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            subscription = null;
            release();
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        final current = subscription;
        subscription = null;
        release();
        await current?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  void close() {
    _closed = true;
    for (final token in _tokens.toList()) {
      token.cancel();
    }
    _tokens.clear();
  }
}
