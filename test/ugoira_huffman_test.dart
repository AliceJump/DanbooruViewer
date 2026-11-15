import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danbooru_viewer/ugoira_archive.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _fixture() => base64Decode(
  File(
    'test/fixtures/ugoira/dynamic_huffman_tail.zip.base64',
  ).readAsStringSync().trim(),
);

int _directoryStart(Uint8List bytes) => ByteData.sublistView(
  bytes,
).getUint32(bytes.length - 22 + 16, Endian.little);

void main() {
  test('independent dynamic Huffman ZIP decodes its short final codes', () {
    final bytes = _fixture();
    final data = ByteData.sublistView(bytes);
    final start =
        30 +
        data.getUint16(26, Endian.little) +
        data.getUint16(28, Endian.little);
    expect((bytes[start] >> 1) & 3, 2, reason: 'fixture is a dynamic block');
    final result = decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 65);
    expect(result.files.single.name, 'tail.bin');
    expect(result.files.single.content, [...List.filled(64, 65), 123]);
  });

  test('tail padding does not bypass the actual output budget', () {
    final bytes = _fixture();
    final directory = _directoryStart(bytes);
    // Lie about the expected length so only actual emitted bytes enforce this.
    ByteData.sublistView(bytes).setUint32(directory + 24, 1, Endian.little);
    expect(
      () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 32),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('超出限制'),
        ),
      ),
    );
  });

  for (final field in ['crc', 'length']) {
    test('tail padding still rejects invalid $field metadata', () {
      final bytes = _fixture();
      final data = ByteData.sublistView(bytes);
      final position = _directoryStart(bytes) + (field == 'crc' ? 16 : 24);
      data.setUint32(
        position,
        data.getUint32(position, Endian.little) + 1,
        Endian.little,
      );
      expect(
        () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 100),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('长度或校验值'),
          ),
        ),
      );
    });
  }

  test('tail padding never extends the permitted compressed-data range', () {
    final bytes = _fixture();
    final data = ByteData.sublistView(bytes);
    final start =
        30 +
        data.getUint16(26, Endian.little) +
        data.getUint16(28, Endian.little);
    final directory = _directoryStart(bytes);
    data.setUint32(directory + 20, directory - start + 1, Endian.little);
    expect(
      () => decodeBoundedUgoiraArchive(bytes, maxOutputBytes: 100),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('文件数据不完整'),
        ),
      ),
    );
  });
}
