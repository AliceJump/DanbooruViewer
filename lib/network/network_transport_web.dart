import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import 'network_errors.dart';
import 'network_settings.dart';

http.Client createNetworkClient(NetworkSettings settings) => BrowserClient();

NetworkException classifyNetworkError(Object error, NetworkSettings settings) =>
    const NetworkException(
      NetworkErrorKind.connection,
      '浏览器请求失败，请检查浏览器代理或站点的跨域访问限制。',
    );
