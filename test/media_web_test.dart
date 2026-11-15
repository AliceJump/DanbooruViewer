import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/media_utils.dart';
import 'package:danbooru_viewer/network/app_cache_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const browserOnly = !kIsWeb;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgmNbxHwAD1gIeATp91AAAAABJRU5ErkJggg==',
  );

  testWidgets(
    'browser cache renders bytes without FileImage or native IO',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const url = 'https://example.test/browser-cache.png';
      await AppCacheManager.instance.putFile(url, png, fileExtension: 'png');
      final provider = await cachedMediaImageProvider(url);
      expect(provider, isA<MemoryImage>());
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(width: 64, height: 64, child: Image(image: provider)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(supportsNativeMediaDrag, isFalse);
      expect(supportsInlineVideo, isTrue);
      await AppCacheManager.instance.removeFile(url);
    },
    skip: browserOnly,
  );

  testWidgets(
    'browser Ugoira conversion stays in the shared memory cache',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const url = 'https://example.test/browser-animation.zip';
      final metadata = utf8.encode(
        jsonEncode({
          'frames': [
            {'file': '000000.png', 'delay': 100},
          ],
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('000000.png', png.length, png))
        ..addFile(ArchiveFile('frame_data.json', metadata.length, metadata));
      final zip = Uint8List.fromList(ZipEncoder().encode(archive));
      await AppCacheManager.instance.putFile(url, zip, fileExtension: 'zip');
      final provider = await cachedMediaImageProvider(url);
      expect(provider, isA<MemoryImage>());
      final bytes = (provider as MemoryImage).bytes;
      expect(ascii.decode(bytes.take(3).toList()), 'GIF');
      await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await AppCacheManager.instance.emptyCache();
    },
    skip: browserOnly,
  );
}
