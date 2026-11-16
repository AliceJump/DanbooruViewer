import 'dart:typed_data';

import 'package:image/image.dart' show ImageException, InputBuffer, WebPInfo;
// These two internal APIs are intentionally paired with the exact image 4.13.1
// dependency. No level-zero decode is allowed during this preflight.
// ignore: implementation_imports
import 'package:image/src/formats/webp/vp8l.dart' show InternalVP8L;
// ignore: implementation_imports
import 'package:image/src/formats/webp/vp8l_bit_reader.dart' show VP8LBitReader;

typedef UgoiraWebpLosslessBudget = ({
  int usedGroups,
  int colorCacheBits,
  int tableEntries,
  int auxiliaryPixels,
});

/// Check the allocation-driving prefix of a VP8L image stream before decoding.
///
/// [stream] must be an isolated payload view AFTER the five-byte VP8L header,
/// or AFTER the one-byte compressed ALPH control header. [width] and [height]
/// are the already validated image dimensions. Both formats use the same
/// transform/cache/meta-Huffman prefix from this point.
///
/// Only auxiliary images are decoded here. Each uses a fresh InternalVP8L with
/// the same bit reader and isLevel0=false: no transforms or meta recursion,
/// exactly one Huffman group, at most 2048 color-cache entries. The caller's
/// eventual full decode repeats those auxiliary images, so both passes count
/// against the budgets. Table entries are object counts, not a process-memory
/// byte limit. Pixel buffers, list/object overhead and the final image are
/// additional and remain subject to the caller's image/animation budgets.
UgoiraWebpLosslessBudget checkUgoiraWebpLosslessBudget(
  Uint8List stream, {
  required int width,
  required int height,
  int maxHuffmanGroups = 64,
  int maxHuffmanTableEntries = 512 * 1024,
  int maxAuxiliaryPixels = 8 * 1024 * 1024,
  int maxEncodedHuffmanGroups = 4096,
}) {
  try {
    return _LosslessPreflight(
      stream,
      width,
      height,
      maxHuffmanGroups,
      maxHuffmanTableEntries,
      maxAuxiliaryPixels,
      maxEncodedHuffmanGroups,
    ).check();
  } on ImageException catch (error) {
    throw FormatException('动图 WebP 辅助编码无效：$error');
  } on RangeError {
    throw const FormatException('动图 WebP 辅助编码越界或不完整。');
  }
}

class _LosslessPreflight {
  _LosslessPreflight(
    this.stream,
    this.width,
    this.height,
    this.maxGroups,
    this.maxTables,
    this.maxAuxiliaryPixels,
    this.maxEncodedGroups,
  ) {
    if (stream.isEmpty ||
        width <= 0 ||
        height <= 0 ||
        width > 16384 ||
        height > 16384) {
      _fail('无损流尺寸或内容无效');
    }
    // VP8LBitReader eagerly prefetches eight bytes. A short valid stream may
    // need fewer. Supply bounded lookahead, but never allow consumed bits to
    // exceed the actual payload; no adjacent RIFF chunk can be read.
    _readerBytes = stream.length >= 8
        ? stream
        : (Uint8List(8)..setRange(0, stream.length, stream));
    _input = InputBuffer(_readerBytes);
    _reader = VP8LBitReader(_input);
  }

  final Uint8List stream;
  int width;
  final int height;
  final int maxGroups;
  final int maxTables;
  final int maxAuxiliaryPixels;
  final int maxEncodedGroups;
  late final Uint8List _readerBytes;
  late final InputBuffer _input;
  late final VP8LBitReader _reader;
  var _tableEntries = 0;
  var _auxiliaryPixels = 0;
  var _auxiliaryImages = 0;

  Never _fail(String reason) => throw FormatException('动图 WebP $reason。');

  UgoiraWebpLosslessBudget check() {
    var transforms = 0;
    while (_read(1) != 0) {
      final type = _read(2);
      final mask = 1 << type;
      if (transforms & mask != 0) _fail('包含重复图像变换');
      transforms |= mask;
      switch (type) {
        case 0 || 1: // Predictor or cross-color transform image.
          final bits = _read(3) + 2;
          _decodeAuxiliary(_subsample(width, bits), _subsample(height, bits));
        case 2: // Subtract green has no auxiliary image.
          break;
        case 3: // Color indexing changes the width seen by later transforms.
          final colors = _read(8) + 1;
          _decodeAuxiliary(colors, 1);
          final bits = colors > 16
              ? 0
              : colors > 4
              ? 1
              : colors > 2
              ? 2
              : 3;
          width = _subsample(width, bits);
      }
    }
    final colorCacheBits = _readCacheBits();
    var usedGroups = 1;
    var encodedGroups = 1;
    if (_read(1) != 0) {
      final bits = _read(3) + 2;
      final meta = _decodeAuxiliary(
        _subsample(width, bits),
        _subsample(height, bits),
      );
      final groups = <int>{};
      for (final pixel in meta) {
        final group = (pixel >> 8) & 0xffff;
        groups.add(group);
        if (groups.length > maxGroups) _fail('Huffman 表组数量超出限制');
        if (group + 1 > encodedGroups) encodedGroups = group + 1;
        if (encodedGroups > maxEncodedGroups) {
          _fail('Huffman 编码表数量超出限制');
        }
      }
      usedGroups = groups.length;
    }
    if (usedGroups > maxGroups || encodedGroups > maxEncodedGroups) {
      _fail('Huffman 表组数量超出限制');
    }
    _reserveTables(usedGroups, encodedGroups, colorCacheBits);
    return (
      usedGroups: usedGroups,
      colorCacheBits: colorCacheBits,
      tableEntries: _tableEntries,
      auxiliaryPixels: _auxiliaryPixels,
    );
  }

  Uint32List _decodeAuxiliary(int columns, int rows) {
    final pixels = columns * rows;
    // At most three image-bearing transforms plus one meta image. This check
    // is independent of the bitstream and forbids a future recursive change.
    if (++_auxiliaryImages > 4 ||
        pixels <= 0 ||
        _auxiliaryPixels + pixels * 2 > maxAuxiliaryPixels) {
      _fail('辅助图像解码预算超出限制');
    }
    _auxiliaryPixels += pixels * 2;
    // Peek without advancing the shared reader: decodeImageStream must read
    // this same cache flag. Auxiliary streams omit the level-zero transforms
    // and meta-Huffman flag, so their group count is always exactly one.
    final cacheBits = _peek(0, 1) == 0 ? 0 : _checkCacheBits(_peek(1, 4));
    _reserveTables(1, 1, cacheBits, passes: 2);
    final info = WebPInfo()
      ..width = columns
      ..height = rows;
    // Construction uses a separate InputBuffer. Its eager prefetch must not
    // advance _input; only the shared _reader subsequently consumes the stream.
    final decoder = InternalVP8L(InputBuffer(_readerBytes), info)..br = _reader;
    final result = decoder.decodeImageStream(columns, rows, false);
    _checkPosition();
    if (result == null || result.length != pixels) {
      _fail('辅助图像解码长度无效');
    }
    return result;
  }

  // image 4.13.1's _tableSize is the worst-case sum of all five lookup trees
  // in one group (8-bit roots, code lengths <=15, cache bits <=11). The valid
  // trees of G used groups therefore require at most N=G*tableSize entries.
  // _vp8lBuildHuffmanTable can add a segment on used+next >= capacity. Since
  // all trees together fit N and each tree <=N, only the equality boundary
  // can add one more N-sized segment: reserve 2*N, not merely the first N.
  // Also count 64 packed entries per group and up to TWO 128-entry code-length
  // table segments for each of the five encoded trees, including unused groups.
  // Summing each allocation (and both auxiliary passes) is conservative even
  // if the runtime does not collect discarded auxiliary tables immediately.
  void _reserveTables(
    int groups,
    int encodedGroups,
    int cacheBits, {
    int passes = 1,
  }) {
    final entries =
        (2 * groups * _tableSizes[cacheBits] +
            64 * groups +
            256 * 5 * encodedGroups) *
        passes;
    if (_tableEntries + entries > maxTables) {
      _fail('Huffman 解码表分配预算超出限制');
    }
    _tableEntries += entries;
  }

  int get _consumedBits => (_input.position - 8) * 8 + _reader.bitPos;

  void _checkPosition() {
    if (_consumedBits < 0 || _consumedBits > stream.length * 8) {
      _fail('无损流被截断');
    }
  }

  int _read(int count) {
    _peek(0, count); // Check the real payload, not padded lookahead.
    final value = _reader.readBits(count);
    _checkPosition();
    return value;
  }

  int _peek(int offset, int count) {
    final start = _consumedBits + offset;
    if (start < 0 || start + count > stream.length * 8) {
      _fail('无损流被截断');
    }
    var value = 0;
    for (var bit = 0; bit < count; bit++) {
      final position = start + bit;
      value |= ((stream[position >> 3] >> (position & 7)) & 1) << bit;
    }
    return value;
  }

  int _readCacheBits() => _read(1) == 0 ? 0 : _checkCacheBits(_read(4));

  int _checkCacheBits(int value) {
    if (value < 1 || value > 11) _fail('颜色缓存参数无效');
    return value;
  }

  static int _subsample(int size, int bits) => (size + (1 << bits) - 1) >> bits;

  static const _tableSizes = [
    2954,
    2956,
    2958,
    2962,
    2970,
    2986,
    3018,
    3082,
    3212,
    3468,
    3980,
    5004,
  ];
}
