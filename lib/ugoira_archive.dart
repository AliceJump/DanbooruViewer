import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'ugoira_inflate.dart';

const maxUgoiraArchiveFiles = 502;
const maxUgoiraMetadataBytes = 1024 * 1024;

/// Decode only the ordinary stored/deflate ZIP format used by Ugoira. Limits
/// apply before parsing an unbounded directory or allocating inflated output.
Archive decodeBoundedUgoiraArchive(
  Uint8List bytes, {
  required int maxOutputBytes,
  int maxFiles = maxUgoiraArchiveFiles,
}) {
  final directory = _validateDirectory(bytes, maxFiles);
  final headers = InputMemoryStream(
    bytes,
    offset: directory.start,
    length: directory.size,
  );
  final budget = _InflateBudget(maxOutputBytes);
  final archive = Archive();
  final names = <String>{};
  while (!headers.isEOS) {
    headers.readUint32(); // Already validated central-directory signature.
    // Read metadata only, without ZipDirectory searching again for a signature
    // in a comment or following an unvalidated ZIP64 directory.
    final header = ZipFileHeader()..read(headers);
    final name = header.filename;
    if (!names.add(name)) {
      throw const FormatException('动图包包含重复文件名。');
    }
    if (name.endsWith('/') || name.endsWith('\\')) continue;
    if (header.uncompressedSize > budget.remaining) {
      throw const FormatException('动图实际解压大小超出限制，请打开原链接查看。');
    }
    final isMetadata = const [
      'frame_data.json',
      'motion.json',
    ].contains(name.toLowerCase());
    final output = _BoundedInflateOutput(
      budget,
      entryLimit: isMetadata ? maxUgoiraMetadataBytes : maxOutputBytes,
    );
    final input = _compressedData(bytes, header, directory.start);
    if (header.compressionMethod == 8) {
      // Keep literal/back-reference writes inside the shared output budget.
      // The pinned decoder accepts a short final Huffman symbol without
      // adding lookahead bytes beyond this validated compressed range.
      inflateUgoiraStream(input, output);
    } else {
      output.writeStream(input);
    }
    final content = output.getBytes();
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != header.crc32) {
      throw const FormatException('动图包的文件长度或校验值不正确。');
    }
    archive.add(ArchiveFile.bytes(name, content));
  }
  return archive;
}

({int start, int size}) _validateDirectory(Uint8List bytes, int maxFiles) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (
    var offset = bytes.length - 22;
    offset >= math.max(0, bytes.length - 65557);
    offset--
  ) {
    if (data.getUint32(offset, Endian.little) == 0x06054b50 &&
        offset + 22 + data.getUint16(offset + 20, Endian.little) ==
            bytes.length) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('动图 ZIP 目录不完整。');
  final count = data.getUint16(eocd + 10, Endian.little);
  final size = data.getUint32(eocd + 12, Endian.little);
  final start = data.getUint32(eocd + 16, Endian.little);
  if (data.getUint16(eocd + 4, Endian.little) != 0 ||
      data.getUint16(eocd + 6, Endian.little) != 0 ||
      data.getUint16(eocd + 8, Endian.little) != count ||
      count == 0xffff ||
      size == 0xffffffff ||
      start == 0xffffffff) {
    throw const FormatException('暂不支持多卷或 ZIP64 格式的动图包。');
  }
  if (count > maxFiles || start + size > eocd) {
    throw const FormatException('动图文件数量超限或 ZIP 目录不完整。');
  }
  var position = start;
  var actualCount = 0;
  final end = start + size;
  while (position < end) {
    if (position + 46 > end ||
        data.getUint32(position, Endian.little) != 0x02014b50) {
      throw const FormatException('动图 ZIP 文件目录无效。');
    }
    if (++actualCount > maxFiles) {
      throw const FormatException('动图文件数量超出限制。');
    }
    final flags = data.getUint16(position + 8, Endian.little);
    final method = data.getUint16(position + 10, Endian.little);
    final mode = data.getUint32(position + 38, Endian.little) >> 16;
    if (flags & 1 != 0 ||
        !const [0, 8].contains(method) ||
        mode & 0xf000 == 0xa000) {
      throw const FormatException('动图包包含加密、符号链接或不支持的压缩格式。');
    }
    if (data.getUint32(position + 20, Endian.little) == 0xffffffff ||
        data.getUint32(position + 24, Endian.little) == 0xffffffff ||
        data.getUint32(position + 42, Endian.little) == 0xffffffff ||
        data.getUint16(position + 34, Endian.little) != 0) {
      throw const FormatException('暂不支持多卷或 ZIP64 格式的动图包。');
    }
    position +=
        46 +
        data.getUint16(position + 28, Endian.little) +
        data.getUint16(position + 30, Endian.little) +
        data.getUint16(position + 32, Endian.little);
    if (position > end) throw const FormatException('动图 ZIP 目录不完整。');
  }
  if (actualCount != count) {
    throw const FormatException('动图 ZIP 文件数量不一致。');
  }
  return (start: start, size: size);
}

InputStream _compressedData(
  Uint8List bytes,
  ZipFileHeader header,
  int directoryStart,
) {
  final data = ByteData.sublistView(bytes);
  final offset = header.localHeaderOffset;
  if (offset + 30 > directoryStart ||
      data.getUint32(offset, Endian.little) != 0x04034b50 ||
      data.getUint16(offset + 6, Endian.little) & 1 != 0 ||
      data.getUint16(offset + 8, Endian.little) != header.compressionMethod) {
    throw const FormatException('动图 ZIP 文件头无效。');
  }
  final start =
      offset +
      30 +
      data.getUint16(offset + 26, Endian.little) +
      data.getUint16(offset + 28, Endian.little);
  if (start + header.compressedSize > directoryStart) {
    throw const FormatException('动图 ZIP 文件数据不完整。');
  }
  return InputMemoryStream(bytes, offset: start, length: header.compressedSize);
}

class _InflateBudget {
  _InflateBudget(this.remaining);
  int remaining;

  void take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('动图实际解压大小超出限制，请打开原链接查看。');
    }
    remaining -= count;
  }
}

class _BoundedInflateOutput extends OutputStream {
  _BoundedInflateOutput(this.budget, {required this.entryLimit})
    : super(byteOrder: ByteOrder.littleEndian);

  final _InflateBudget budget;
  final int entryLimit;
  final _buffer = OutputMemoryStream();

  void _reserve(int count) {
    if (count > entryLimit - length) {
      throw const FormatException('动图文件或帧元数据大小超出限制。');
    }
    budget.take(count);
  }

  @override
  int get length => _buffer.length;

  @override
  void clear() => _buffer.clear();

  @override
  void flush() => _buffer.flush();

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
}
