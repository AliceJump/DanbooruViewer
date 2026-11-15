import 'dart:async';
import 'dart:typed_data';

import 'package:danbooru_viewer/network/network_errors.dart';
import 'package:danbooru_viewer/ugoira_conversion_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'conversions run one at a time and a failed job releases the next',
    () async {
      final first = Completer<Uint8List>();
      final started = <int>[];
      final queue = UgoiraConversionQueue((bytes, _) async {
        started.add(bytes.single);
        if (bytes.single == 1) return first.future;
        return bytes;
      });
      final failed = expectLater(
        queue.convert(Uint8List.fromList([1])),
        throwsA(isA<FormatException>()),
      );
      final second = queue.convert(Uint8List.fromList([2]));
      expect(started, [1]);
      first.completeError(const FormatException('bad archive'));
      await failed;
      expect(await second, [2]);
      expect(started, [1, 2]);
    },
  );

  test('queue bounds task count independently of ZIP size', () async {
    final first = Completer<Uint8List>();
    final queue = UgoiraConversionQueue(
      (bytes, _) => bytes.single == 1 ? first.future : Future.value(bytes),
      maxTasks: 2,
    );
    final active = queue.convert(Uint8List.fromList([1]));
    final waiting = queue.convert(Uint8List.fromList([2]));
    await expectLater(
      queue.convert(Uint8List.fromList([3])),
      throwsA(isA<FormatException>()),
    );
    first.complete(Uint8List.fromList([1]));
    expect(await active, [1]);
    expect(await waiting, [2]);
    expect(await queue.convert(Uint8List.fromList([3])), [3]);
  });

  test('queue bounds retained bytes across active and waiting ZIPs', () async {
    final first = Completer<Uint8List>();
    final queue = UgoiraConversionQueue(
      (bytes, _) => bytes.first == 1 ? first.future : Future.value(bytes),
      maxInputBytes: 3,
    );
    final active = queue.convert(Uint8List.fromList([1, 1]));
    await expectLater(
      queue.convert(Uint8List.fromList([2, 2])),
      throwsA(isA<FormatException>()),
    );
    final waiting = queue.convert(Uint8List.fromList([3]));
    first.complete(Uint8List.fromList([1]));
    await active;
    expect(await waiting, [3]);
    expect(await queue.convert(Uint8List.fromList([2, 2])), [2, 2]);
  });

  test(
    'queued cancellation releases bytes and never starts its decoder',
    () async {
      final first = Completer<Uint8List>();
      final started = <int>[];
      final queue = UgoiraConversionQueue((bytes, _) async {
        started.add(bytes.first);
        return bytes.first == 1 ? first.future : bytes;
      }, maxInputBytes: 3);
      final active = queue.convert(Uint8List.fromList([1]));
      final token = NetworkCancelToken();
      final cancelled = expectLater(
        queue.convert(Uint8List.fromList([2, 2]), cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
      token.cancel();
      await cancelled;
      final replacement = queue.convert(Uint8List.fromList([3, 3]));
      expect(started, [1]);
      first.complete(Uint8List.fromList([1]));
      await active;
      expect(await replacement, [3, 3]);
      expect(started, [1, 3]);
    },
  );

  test(
    'active cancellation waits for worker cleanup before the next job',
    () async {
      final cancelled = Completer<void>();
      final cleanedUp = Completer<void>();
      final started = <int>[];
      final queue = UgoiraConversionQueue((bytes, token) async {
        started.add(bytes.single);
        if (bytes.single != 1) return bytes;
        final remove = token.addListener(cancelled.complete);
        try {
          await cancelled.future;
          await cleanedUp.future;
          token.throwIfCancelled();
          return bytes;
        } finally {
          remove();
        }
      });
      final token = NetworkCancelToken();
      final failed = expectLater(
        queue.convert(Uint8List.fromList([1]), cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
      final next = queue.convert(Uint8List.fromList([2]));
      token.cancel();
      await cancelled.future;
      expect(started, [1]);
      cleanedUp.complete();
      await failed;
      expect(await next, [2]);
      expect(started, [1, 2]);
    },
  );

  test('pre-cancelled input never enters the operation', () async {
    var starts = 0;
    final queue = UgoiraConversionQueue((bytes, _) async {
      starts++;
      return bytes;
    });
    await expectLater(
      queue.convert(
        Uint8List.fromList([1]),
        cancelToken: NetworkCancelToken()..cancel(),
      ),
      throwsA(isA<NetworkCancelledException>()),
    );
    expect(starts, 0);
  });
}
