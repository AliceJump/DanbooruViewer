import 'dart:io';

/// Run after `flutter pub get` with the Dart SDK shipped in the pinned Flutter.
/// All platforms generate the asset because Flutter 3.38 has no per-platform
/// asset declarations; only the browser loads or executes it.
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final temporary = await Directory.systemTemp.createTemp('ugoira-worker-');
  try {
    final compiled = File('${temporary.path}/ugoira_worker.js');
    final process = await Process.start(Platform.resolvedExecutable, [
      'compile',
      'js',
      '-O2',
      '--no-source-maps',
      'tool/ugoira_worker.dart',
      '-o',
      compiled.path,
    ], workingDirectory: root.path);
    await Future.wait([
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr),
    ]);
    final code = await process.exitCode;
    if (code != 0) {
      exitCode = code;
      return;
    }
    final destination = File('${root.path}/assets/ugoira_worker.js');
    await destination.parent.create(recursive: true);
    await compiled.copy(destination.path);
    // Flutter 3.38's Chrome test server serves test/, not the app asset bundle.
    // Give its real Worker tests the identical compiled bytes through that
    // server; the test adapter supplies only the ignored flutter/assets reply.
    final testAsset = File('${root.path}/test/generated/ugoira_worker.js');
    await testAsset.parent.create(recursive: true);
    await compiled.copy(testAsset.path);
    stdout.writeln('Built Ugoira worker and identical browser-test asset');
  } finally {
    await temporary.delete(recursive: true);
  }
}
