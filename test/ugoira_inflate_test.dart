import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:danbooru_viewer/ugoira_inflate.dart';
import 'package:flutter_test/flutter_test.dart';

class _BudgetSink extends OutputStream {
  _BudgetSink(this.limit) : super(byteOrder: ByteOrder.littleEndian);

  final int limit;
  final _buffer = OutputMemoryStream();

  @override
  int get length => _buffer.length;

  void _reserve(int count) {
    if (count > limit - length) throw const FormatException('test budget');
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _buffer.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    _buffer.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    _buffer.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _buffer.subset(start, end);

  @override
  void clear() => _buffer.clear();

  @override
  void flush() {}
}

void main() {
  // A small ordinary single Huffman block, with enough literal data remaining
  // after the first few bytes to observe whether the sink is called early.
  final plain = Uint8List.fromList(List.generate(4096, (i) => i & 255));
  final compressed = Deflate(plain).getBytes();

  test(
    'output budget stops inside a compressed block before reading it all',
    () {
      expect(compressed.first & 1, 1); // One final block.
      expect((compressed.first >> 1) & 3, anyOf(1, 2)); // Huffman coding.
      final input = InputMemoryStream(compressed);
      final output = _BudgetSink(8);
      expect(() => inflateUgoiraStream(input, output), throwsFormatException);
      expect(output.length, 8);
      expect(input.position, lessThan(compressed.length ~/ 2));
    },
  );

  test(
    'bounded sink retains literal and overlapping back-reference output',
    () {
      final output = _BudgetSink(plain.length);
      inflateUgoiraStream(InputMemoryStream(compressed), output);
      expect(output.getBytes(), plain);
    },
  );

  test(
    'truncated final block is rejected instead of accepting partial data',
    () {
      final input = InputMemoryStream(
        Uint8List.sublistView(compressed, 0, compressed.length - 1),
      );
      expect(
        () => inflateUgoiraStream(input, _BudgetSink(plain.length)),
        throwsA(isA<ArchiveException>()),
      );
    },
  );
}
