@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:danbooru_viewer/media_save_service.dart';
import 'package:danbooru_viewer/media_save_types.dart';
import 'package:danbooru_viewer/network/network_errors.dart';
import 'package:danbooru_viewer/ugoira_conversion_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queued cancellation removes the source before it is read', () async {
    final firstEncoding = Completer<Uint8List>();
    final firstStarted = Completer<void>();
    final reads = <int>[];
    final converter = NativeUgoiraConverter(
      encode: (bytes) async {
        if (bytes.single == 1) {
          firstStarted.complete();
          return firstEncoding.future;
        }
        return bytes;
      },
    );
    Future<Uint8List> read(int value) async {
      reads.add(value);
      return Uint8List.fromList([value]);
    }

    final first = converter.convert(() => read(1));
    await firstStarted.future;
    final token = NetworkCancelToken();
    final cancelled = expectLater(
      converter.convert(() => read(2), cancelToken: token),
      throwsA(isA<NetworkCancelledException>()),
    );
    final third = converter.convert(() => read(3));
    token.cancel();
    await cancelled;
    expect(reads, [1]);
    firstEncoding.complete(Uint8List.fromList([1]));
    expect(await first, [1]);
    expect(await third, [3]);
    expect(reads, [1, 3]);
  });

  test(
    'running cancellation holds its slot until the isolate completes',
    () async {
      final firstEncoding = Completer<Uint8List>();
      final firstStarted = Completer<void>();
      final reads = <int>[];
      var activeEncoders = 0;
      var peakEncoders = 0;
      final converter = NativeUgoiraConverter(
        encode: (bytes) async {
          activeEncoders++;
          if (activeEncoders > peakEncoders) peakEncoders = activeEncoders;
          try {
            if (bytes.single == 1) {
              firstStarted.complete();
              return await firstEncoding.future;
            }
            return bytes;
          } finally {
            activeEncoders--;
          }
        },
      );
      Future<Uint8List> read(int value) async {
        reads.add(value);
        return Uint8List.fromList([value]);
      }

      final token = NetworkCancelToken();
      var cancellationReturned = false;
      final cancelled = expectLater(
        converter.convert(() => read(1), cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      ).then((_) => cancellationReturned = true);
      await firstStarted.future;
      final next = converter.convert(() => read(2));
      token.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancellationReturned, isFalse);
      expect(reads, [1]);
      expect(activeEncoders, 1);
      firstEncoding.complete(Uint8List.fromList([1]));
      await cancelled;
      expect(await next, [2]);
      expect(peakEncoders, 1);
      expect(activeEncoders, 0);
    },
  );

  test(
    'cancelled active input cannot start an encoder or overlap the next read',
    () async {
      final firstInput = Completer<Uint8List>();
      var secondRead = false;
      final encoded = <int>[];
      final converter = NativeUgoiraConverter(
        encode: (bytes) async {
          encoded.add(bytes.single);
          return bytes;
        },
      );
      final token = NetworkCancelToken();
      final cancelled = expectLater(
        converter.convert(() => firstInput.future, cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
      final next = converter.convert(() async {
        secondRead = true;
        return Uint8List.fromList([2]);
      });
      token.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(secondRead, isFalse);
      firstInput.complete(Uint8List.fromList([1]));
      await cancelled;
      expect(await next, [2]);
      expect(encoded, [2]);
    },
  );

  test(
    'an isolate error after cancellation still reports cancellation',
    () async {
      final encoding = Completer<Uint8List>();
      final started = Completer<void>();
      final converter = NativeUgoiraConverter(
        encode: (bytes) async {
          if (bytes.single == 1) {
            started.complete();
            return encoding.future;
          }
          return bytes;
        },
      );
      final token = NetworkCancelToken();
      final cancelled = expectLater(
        converter.convert(
          () async => Uint8List.fromList([1]),
          cancelToken: token,
        ),
        throwsA(isA<NetworkCancelledException>()),
      );
      await started.future;
      final next = converter.convert(() async => Uint8List.fromList([2]));
      token.cancel();
      encoding.completeError(const FormatException('failed during decoding'));
      await cancelled;
      expect(await next, [2]);
    },
  );

  test(
    'failed and oversized inputs release the slot before the next source',
    () async {
      var encoded = 0;
      final converter = NativeUgoiraConverter(
        maxInputBytes: 3,
        encode: (bytes) async {
          encoded++;
          return bytes;
        },
      );
      final missing = expectLater(
        converter.convert(() async => throw StateError('source unavailable')),
        throwsStateError,
      );
      final oversized = expectLater(
        converter.convert(() async => Uint8List(4)),
        throwsA(isA<FormatException>()),
      );
      final valid = converter.convert(() async => Uint8List.fromList([1]));
      await missing;
      await oversized;
      expect(await valid, [1]);
      expect(encoded, 1);
      await expectLater(
        converter.convertBytes(Uint8List(4)),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'already loaded bytes are not retained behind an active conversion',
    () async {
      final input = Completer<Uint8List>();
      final converter = NativeUgoiraConverter(encode: (bytes) async => bytes);
      final first = converter.convert(() => input.future);
      await expectLater(
        converter.convertBytes(Uint8List.fromList([2])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('忙碌'),
          ),
        ),
      );
      input.complete(Uint8List.fromList([1]));
      expect(await first, [1]);
      expect(await converter.convertBytes(Uint8List.fromList([2])), [2]);
    },
  );

  test('pre-cancelled callers never read a source', () async {
    var reads = 0;
    final converter = NativeUgoiraConverter(encode: (bytes) async => bytes);
    await expectLater(
      converter.convert(() async {
        reads++;
        return Uint8List.fromList([1]);
      }, cancelToken: NetworkCancelToken()..cancel()),
      throwsA(isA<NetworkCancelledException>()),
    );
    expect(reads, 0);
  });

  test(
    'queued save cancellation does not open its HTTP or local source',
    () async {
      final activeInput = Completer<Uint8List>();
      final token = NetworkCancelToken();
      final active = expectLater(
        convertUgoiraToGif(() => activeInput.future),
        throwsA(isA<FormatException>()),
      );
      var opened = false;
      final cancelled = expectLater(
        convertUgoiraForSave(() async {
          opened = true;
          return const MediaSaveInput(Stream.empty());
        }, cancelToken: token),
        throwsA(isA<NetworkCancelledException>()),
      );
      token.cancel();
      await cancelled;
      expect(opened, isFalse);
      activeInput.complete(Uint8List.fromList([1, 2, 3]));
      await active;
    },
  );
}
