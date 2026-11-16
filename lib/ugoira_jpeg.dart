import 'dart:typed_data';

/// Validate JPEG before image 4.8.0's readInfo/read can allocate DCT blocks.
///
/// The coefficient budget counts the actual Int32List(64) backing storage,
/// including MCU padding for every component. Dart list/object and output
/// image overhead are additional; this is not a process memory limit.
/// Only one 8-bit Huffman DCT frame is accepted. The returned bytes retain
/// validated coding segments and entropy, a bounded Adobe color transform,
/// and at most a fixed-size EXIF orientation segment. Callers must decode
/// these bytes directly after checking the returned pixel count, without
/// invoking JpegDecoder.startDecode (which also allocates the coefficients).
({Uint8List bytes, int width, int height}) prepareUgoiraJpeg(
  Uint8List bytes, {
  required int maxPixels,
  required int maxCoefficientBytes,
}) => _JpegPreparation(bytes, maxPixels, maxCoefficientBytes).prepare();

class _JpegComponent {
  _JpegComponent(this.h, this.v, this.quantization);

  final int h;
  final int v;
  final int quantization;
  final approximation = List<int>.filled(64, -1);
}

class _JpegPreparation {
  _JpegPreparation(this.bytes, this.maxPixels, this.maxCoefficientBytes);

  final Uint8List bytes;
  final int maxPixels;
  final int maxCoefficientBytes;
  final _body = <List<int>>[];
  final _components = <int, _JpegComponent>{};
  final _quantization = <int>{};
  final _huffman = <int>{};
  int _position = 2;
  int _width = 0;
  int _height = 0;
  int _frame = 0;
  int _restartInterval = 0;
  int _scans = 0;
  int _normalizedRestarts = 0;
  int? _orientation;
  int? _adobeTransform;

  Never _fail(String reason) => throw FormatException('动图 JPEG $reason');

  int _uint16(int offset) => bytes[offset] * 256 + bytes[offset + 1];

  void _segment(void Function(List<int>) add, int marker, List<int> payload) {
    final length = payload.length + 2;
    add([0xff, marker, length >> 8, length & 255]);
    add(payload);
  }

  ({Uint8List bytes, int width, int height}) prepare() {
    if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) {
      _fail('文件头无效。');
    }
    var segments = 0;
    var ended = false;
    while (_position < bytes.length) {
      if (++segments > 4096) _fail('数据段数量超出限制。');
      if (bytes[_position++] != 0xff) _fail('数据段边界不明确。');
      while (_position < bytes.length && bytes[_position] == 0xff) {
        _position++;
      }
      if (_position >= bytes.length) _fail('数据段不完整。');
      final marker = bytes[_position++];
      if (marker == 0xd9) {
        ended = true;
        break;
      }
      if (marker == 0 || marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) {
        _fail('包含重复图像头或无效标记。');
      }
      if (_position + 2 > bytes.length) _fail('数据段长度缺失。');
      final length = _uint16(_position);
      final start = _position + 2;
      final end = _position + length;
      if (length < 2 || end > bytes.length) _fail('数据段长度无效。');
      _position = end;

      if (marker >= 0xe0 && marker <= 0xef || marker == 0xfe) {
        if (marker == 0xe1) {
          _orientation = _readOrientation(start, end) ?? _orientation;
        } else if (marker == 0xee) {
          _readAdobe(start, end);
        }
        continue;
      }
      switch (marker) {
        case 0xc0 || 0xc1 || 0xc2:
          _readFrame(marker, start, end);
        case 0xdb:
          _readQuantization(start, end);
        case 0xc4:
          _readHuffman(start, end);
        case 0xdd:
          if (end - start != 2) _fail('重启间隔数据无效。');
          _restartInterval = _uint16(start);
        case 0xda:
          _readScan(start, end);
        default:
          _fail('编码标记不受支持。');
      }
      _segment(_body.add, marker, Uint8List.sublistView(bytes, start, end));
      if (marker == 0xda) _readEntropy();
    }
    if (!ended || _position != bytes.length || _frame == 0 || _scans == 0) {
      _fail('图像不完整或包含额外数据。');
    }
    if (_components.values.any((component) => component.approximation[0] < 0)) {
      _fail('缺少颜色组件的扫描数据。');
    }
    if (_components.length == 4 && _adobeTransform == null) {
      _fail('四通道图像缺少受支持的颜色变换。');
    }
    if (_adobeTransform == 2 && _components.length != 4 ||
        _adobeTransform == 1 && _components.length == 4) {
      _fail('颜色变换与组件不匹配。');
    }
    final output = BytesBuilder(copy: false)..add(const [0xff, 0xd8]);
    final orientation = _orientation;
    if (orientation != null) {
      // A single inline SHORT; no original TIFF pointers or nested IFDs.
      _segment(output.add, 0xe1, [
        69,
        120,
        105,
        102,
        0,
        0,
        77,
        77,
        0,
        42,
        0,
        0,
        0,
        8,
        0,
        1,
        1,
        18,
        0,
        3,
        0,
        0,
        0,
        1,
        0,
        orientation,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
    }
    final transform = _adobeTransform;
    if (transform != null) {
      _segment(output.add, 0xee, [
        65,
        100,
        111,
        98,
        101,
        0,
        100,
        0,
        0,
        0,
        0,
        transform,
      ]);
    }
    // Segment views stay bounded by the marker limit; ordinary restart
    // markers do not create one object per MCU. Copy only the final buffer.
    for (final part in _body) {
      output.add(part);
    }
    output.add(const [0xff, 0xd9]);
    return (bytes: output.takeBytes(), width: _width, height: _height);
  }

  void _readFrame(int marker, int start, int end) {
    if (_frame != 0) _fail('包含多个帧头。');
    if (end - start < 6 || bytes[start] != 8) {
      _fail('只支持 8 位 DCT 图像。');
    }
    _height = _uint16(start + 1);
    _width = _uint16(start + 3);
    if (_width == 0 || _height == 0 || _width * _height > maxPixels) {
      _fail('解码尺寸过大或无效。');
    }
    final count = bytes[start + 5];
    if (!const [1, 3, 4].contains(count) || end - start != 6 + count * 3) {
      _fail('颜色组件数量或帧头长度无效。');
    }
    var maxH = 0;
    var maxV = 0;
    var blocksPerMcu = 0;
    for (var offset = start + 6; offset < end; offset += 3) {
      final id = bytes[offset];
      final h = bytes[offset + 1] >> 4;
      final v = bytes[offset + 1] & 15;
      final q = bytes[offset + 2];
      if (_components.containsKey(id) ||
          h < 1 ||
          h > 4 ||
          v < 1 ||
          v > 4 ||
          q > 3) {
        _fail('颜色组件或采样参数无效。');
      }
      _components[id] = _JpegComponent(h, v, q);
      if (h > maxH) maxH = h;
      if (v > maxV) maxV = v;
      blocksPerMcu += h * v;
    }
    // image's ComponentData uses shifts: only 1x, 2x and 4x sampling ratios
    // are decoded correctly. Reject unsupported ratios instead of allocating
    // a different layout from the one it will subsequently read.
    for (final component in _components.values) {
      bool supported(int maximum, int samples) =>
          maximum == samples ||
          maximum == samples * 2 ||
          maximum == samples * 4;
      if (!supported(maxH, component.h) || !supported(maxV, component.v)) {
        _fail('采样比例不受支持。');
      }
    }
    final columns = (_width + 8 * maxH - 1) ~/ (8 * maxH);
    final rows = (_height + 8 * maxV - 1) ~/ (8 * maxV);
    final coefficientBytes = columns * rows * blocksPerMcu * 64 * 4;
    if (coefficientBytes > maxCoefficientBytes) _fail('系数块内存超出限制。');
    _frame = marker;
  }

  void _readQuantization(int start, int end) {
    if (start == end) _fail('量化表为空。');
    var offset = start;
    while (offset < end) {
      final descriptor = bytes[offset++];
      final precision = descriptor >> 4;
      final id = descriptor & 15;
      final size = precision == 0 ? 64 : 128;
      if (precision > 1 || id > 3 || offset + size > end) {
        _fail('量化表长度或编号无效。');
      }
      for (var i = 0; i < size; i += precision + 1) {
        final value = precision == 0 ? bytes[offset + i] : _uint16(offset + i);
        if (value == 0) _fail('量化表包含零值。');
      }
      _quantization.add(id);
      offset += size;
    }
  }

  void _readHuffman(int start, int end) {
    if (start == end) _fail('Huffman 表为空。');
    var offset = start;
    while (offset < end) {
      if (end - offset < 17) _fail('Huffman 表不完整。');
      final descriptor = bytes[offset++];
      if (descriptor & 0xec != 0) _fail('Huffman 表编号无效。');
      var symbols = 0;
      var freeCodes = 1;
      for (var i = 0; i < 16; i++) {
        final count = bytes[offset++];
        symbols += count;
        freeCodes = freeCodes * 2 - count;
        if (freeCodes <= 0) _fail('Huffman 码长无效。');
      }
      if (symbols == 0 || symbols > 256 || offset + symbols > end) {
        _fail('Huffman 符号数量无效。');
      }
      for (var i = 0; i < symbols; i++) {
        final value = bytes[offset + i];
        if (descriptor < 0x10 ? value > 11 : value & 15 > 10) {
          _fail('Huffman 样本精度不受支持。');
        }
      }
      _huffman.add(descriptor);
      offset += symbols;
    }
  }

  void _readScan(int start, int end) {
    if (_frame == 0 || end - start < 6) _fail('扫描数据缺少有效帧头。');
    final count = bytes[start];
    if (count < 1 ||
        count > _components.length ||
        end - start != 4 + count * 2) {
      _fail('扫描组件数量或长度无效。');
    }
    final first = bytes[end - 3];
    final last = bytes[end - 2];
    final previous = bytes[end - 1] >> 4;
    final approximation = bytes[end - 1] & 15;
    final progressive = _frame == 0xc2;
    if (progressive) {
      if (first > last ||
          last > 63 ||
          (first == 0 ? last != 0 : count != 1) ||
          previous > 13 ||
          approximation > 13 ||
          previous != 0 && previous != approximation + 1) {
        _fail('渐进扫描参数无效。');
      }
    } else if (first != 0 ||
        last != 63 ||
        previous != 0 ||
        approximation != 0) {
      _fail('顺序扫描参数无效。');
    }
    final ids = <int>{};
    for (var offset = start + 1; offset < end - 3; offset += 2) {
      final id = bytes[offset];
      final component = _components[id];
      final dc = bytes[offset + 1] >> 4;
      final ac = bytes[offset + 1] & 15;
      if (component == null ||
          !ids.add(id) ||
          dc > 3 ||
          ac > 3 ||
          !_quantization.contains(component.quantization)) {
        _fail('扫描组件或量化表无效。');
      }
      if ((!progressive || first == 0 && previous == 0) &&
              !_huffman.contains(dc) ||
          (!progressive || first > 0) && !_huffman.contains(0x10 | ac)) {
        _fail('扫描缺少 Huffman 表。');
      }
      if (first > 0 && component.approximation[0] < 0) {
        _fail('渐进扫描缺少初始 DC 数据。');
      }
      for (var coefficient = first; coefficient <= last; coefficient++) {
        final old = component.approximation[coefficient];
        if (previous == 0 ? old != -1 : old != previous) {
          _fail('扫描重复或渐进精度不连续。');
        }
        component.approximation[coefficient] = approximation;
      }
    }
    _scans++;
  }

  void _readEntropy() {
    var start = _position;
    var dataBytes = 0;
    var restart = 0;
    while (_position < bytes.length) {
      if (bytes[_position] != 0xff) {
        _position++;
        dataBytes++;
        continue;
      }
      final markerStart = _position++;
      while (_position < bytes.length && bytes[_position] == 0xff) {
        _position++;
      }
      if (_position >= bytes.length) _fail('扫描数据被截断。');
      final marker = bytes[_position++];
      if (marker == 0) {
        if (_position != markerStart + 2) _fail('扫描转义字节不明确。');
        dataBytes++;
        continue;
      }
      if (marker >= 0xd0 && marker <= 0xd7) {
        if (_restartInterval == 0 || marker != 0xd0 + restart) {
          _fail('扫描重启标记无效。');
        }
        restart = (restart + 1) & 7;
        if (_position != markerStart + 2) {
          // Normalize unusual fill bytes for image's two-byte RST reader.
          // Keep the number of retained views bounded even for tiny scans.
          if (++_normalizedRestarts > 4096) _fail('重启标记填充过多。');
          _body
            ..add(Uint8List.sublistView(bytes, start, markerStart))
            ..add([0xff, marker]);
          start = _position;
        }
        continue;
      }
      if (dataBytes == 0) _fail('扫描不包含图像数据。');
      _body.add(Uint8List.sublistView(bytes, start, markerStart));
      _position = markerStart;
      return;
    }
    _fail('缺少图像结束标记。');
  }

  void _readAdobe(int start, int end) {
    const signature = [65, 100, 111, 98, 101, 0];
    if (end - start < 12) return;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[start + i] != signature[i]) return;
    }
    final transform = bytes[start + 11];
    if (transform > 2 ||
        _adobeTransform != null && _adobeTransform != transform) {
      _fail('Adobe 颜色变换不明确。');
    }
    _adobeTransform = transform;
  }

  int? _readOrientation(int start, int end) {
    const signature = [69, 120, 105, 102, 0, 0];
    if (end - start < 14) return null;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[start + i] != signature[i]) return null;
    }
    final tiff = start + 6;
    final Endian endian;
    if (bytes[tiff] == 73 && bytes[tiff + 1] == 73) {
      endian = Endian.little;
    } else if (bytes[tiff] == 77 && bytes[tiff + 1] == 77) {
      endian = Endian.big;
    } else {
      return null;
    }
    final view = ByteData.sublistView(bytes, tiff, end);
    if (view.getUint16(2, endian) != 42) return null;
    final offset = view.getUint32(4, endian);
    if (offset < 8 || offset + 2 > view.lengthInBytes) return null;
    final count = view.getUint16(offset, endian);
    if (count > 256 || offset + 2 + count * 12 + 4 > view.lengthInBytes) {
      return null;
    }
    int? orientation;
    for (var i = 0; i < count; i++) {
      final entry = offset + 2 + i * 12;
      if (view.getUint16(entry, endian) != 0x0112) continue;
      if (orientation != null ||
          view.getUint16(entry + 2, endian) != 3 ||
          view.getUint32(entry + 4, endian) != 1) {
        return null;
      }
      final value = view.getUint16(entry + 8, endian);
      if (value < 1 || value > 8) return null;
      orientation = value;
    }
    return orientation;
  }
}
