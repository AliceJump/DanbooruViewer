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
    stdout.writeln('Built assets/ugoira_worker.js');
  } finally {
    await temporary.delete(recursive: true);
  }
}
