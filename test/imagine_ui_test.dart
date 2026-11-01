import 'package:danbooru_viewer/app_theme.dart';
import 'package:danbooru_viewer/gallery_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gallery column count adapts to screen width', () {
    expect(galleryColumnCount(320), 2);
    expect(galleryColumnCount(800), 4);
    expect(galleryColumnCount(1400), 8);
  });

  test('theme uses flat cards and supports light and dark palettes', () {
    final light = AppTheme.light();
    final dark = AppTheme.dark();

    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(light.cardTheme.elevation, 0);
    expect(dark.cardTheme.elevation, 0);
    expect(light.textTheme.bodyLarge?.fontSize, 16);
    expect(dark.textTheme.bodyLarge?.fontSize, 16);
  });

  testWidgets('gallery grid uses its available width', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 400,
              child: GalleryGrid(itemCount: 0, itemBuilder: _emptyTile),
            ),
          ),
        ),
      ),
    );

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 2);
  });
}

Widget _emptyTile(BuildContext context, int index) {
  return const SizedBox.shrink();
}
