enum NetworkErrorKind {
  cancelled,
  timeout,
  connection,
  tls,
  proxy,
  http,
  invalidResponse,
}

class NetworkException implements Exception {
  const NetworkException(this.kind, this.message, {this.statusCode});

  final NetworkErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class NetworkCancelledException extends NetworkException {
  const NetworkCancelledException([String message = '请求已取消。'])
    : super(NetworkErrorKind.cancelled, message);
}

/// Applies to the initial URL and every native HTTP redirect, including
/// redirects that reuse an existing connection without invoking its factory.
void validateNetworkUri(Uri uri) {
  if (!const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const NetworkException(
      NetworkErrorKind.invalidResponse,
      '仅支持不包含账号密码且端口有效的 HTTP 或 HTTPS 地址。',
    );
  }
}

/// Does not retain raw exception strings, URLs, headers or proxy credentials.
String networkErrorMessage(Object error) =>
    error is NetworkException ? error.message : '网络请求失败，请检查连接或代理设置后重试。';

String httpStatusMessage(int statusCode) => switch (statusCode) {
  401 => '服务器要求登录或认证（HTTP 401）。',
  403 => '服务器拒绝访问（HTTP 403），请检查访问权限或代理线路。',
  404 => '内容不存在或已被删除（HTTP 404）。',
  407 => '代理要求账号密码（HTTP 407），当前版本不支持代理认证。',
  429 => '请求过于频繁（HTTP 429），请稍后重试。',
  >= 500 && <= 599 => '服务器暂时不可用（HTTP $statusCode），请稍后重试。',
  _ => '服务器返回 HTTP $statusCode，请稍后重试。',
};

class NetworkCancelToken {
  bool _cancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _cancelled;

  void throwIfCancelled() {
    if (_cancelled) throw const NetworkCancelledException();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}
