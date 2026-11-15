import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Flutter 3.38's browser test environment intentionally ignores platform
/// messages without invoking their callbacks, including flutter/assets. Unlike
/// VM tests, its mockFlutterAssets is a no-op. Supply that single reply from the
/// actual generated JavaScript served over HTTP by the test server. The real
/// production rootBundle loader, Blob Worker, codec and cancellation still run.
void useGeneratedBrowserWorkerAsset() {
  if (!kIsWeb) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  const assetKey = 'assets/ugoira_worker.js';
  late Uint8List bytes;

  setUpAll(() async {
    // FlutterWebPlatform serves the repository's test/ directory at the test
    // origin root. build_ugoira_worker.dart copies the exact output here.
    final uri = Uri.base.resolve('/generated/ugoira_worker.js');
    final client = http.Client();
    final http.Response response;
    try {
      response = await client
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('Timed out loading generated Worker: $uri'),
          );
    } finally {
      client.close();
    }
    expect(
      response.statusCode,
      200,
      reason: 'Run dart run tool/build_ugoira_worker.dart before Chrome tests.',
    );
    bytes = response.bodyBytes;
    expect(
      bytes,
      isNotEmpty,
      reason: 'The generated Worker must not be empty.',
    );
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          if (message == null) return null;
          final key = utf8.decode(
            message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          return key == assetKey ? ByteData.sublistView(bytes) : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });
}
