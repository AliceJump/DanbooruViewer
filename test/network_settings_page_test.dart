import 'package:danbooru_viewer/network/app_network_service.dart';
import 'package:danbooru_viewer/network/network_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final size in [
    const Size(375, 812),
    const Size(320, 300),
    const Size(1440, 900),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('network form supports $size / $brightness / large text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = AppNetworkService.forTesting(
          settings: const NetworkSettings(mode: NetworkMode.http),
        );
        addTearDown(service.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: brightness,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: NetworkSettingsPage(service: service),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const ValueKey('save-network')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('save-network')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('网络设置已保存，新请求将使用此设置。'), findsOneWidget);
      });
    }
  }

  testWidgets('invalid proxy is shown inline and never applied', (
    tester,
  ) async {
    final service = AppNetworkService.forTesting(
      settings: const NetworkSettings(mode: NetworkMode.http),
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(home: NetworkSettingsPage(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proxy-host')),
      'user:password@localhost',
    );
    await tester.enterText(find.byKey(const ValueKey('proxy-port')), '65536');
    await tester.ensureVisible(find.byKey(const ValueKey('save-network')));
    await tester.tap(find.byKey(const ValueKey('save-network')));
    await tester.pumpAndSettle();
    expect(service.revision, 0);
    expect(find.text('端口必须为 1–65535 的整数。'), findsOneWidget);
    expect(find.text('只填写主机或 IP，不要包含协议、端口、路径或账号密码。'), findsOneWidget);
  });

  testWidgets('web hides unavailable proxy controls', (tester) async {
    final service = AppNetworkService.forTesting();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkSettingsPage(service: service, browserManaged: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-mode')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-host')), findsNothing);
    expect(find.byKey(const ValueKey('proxy-port')), findsNothing);
    expect(find.textContaining('网页版使用浏览器网络'), findsOneWidget);
  });

  testWidgets(
    'API and image CDN are tested separately through saved settings',
    (tester) async {
      final requested = <Uri>[];
      final service = AppNetworkService.forTesting(
        clientFactory: (_) => MockClient((request) async {
          requested.add(request.url);
          if (request.url.host == 'danbooru.donmai.us') {
            return http.Response(
              '[{"preview_file_url":"https://cdn.example.test/image.jpg"}]',
              200,
            );
          }
          return http.Response('image sample', 206);
        }),
      );
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: NetworkSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('测试 API'));
      await tester.tap(find.text('测试 API'));
      await tester.pumpAndSettle();
      expect(find.textContaining('API：连接成功'), findsOneWidget);
      expect(requested.length, 1);
      await tester.ensureVisible(find.text('测试图片 CDN'));
      await tester.tap(find.text('测试图片 CDN'));
      await tester.pumpAndSettle();
      expect(find.textContaining('图片 CDN：连接成功'), findsOneWidget);
      expect(requested.map((uri) => uri.host), [
        'danbooru.donmai.us',
        'danbooru.donmai.us',
        'cdn.example.test',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
