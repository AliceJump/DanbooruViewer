"""Build a valid, deliberately unbalanced dynamic-DEFLATE ZIP fixture.

The independent Python zlib and zipfile decoders validate the result. No Dart
archive encoder is used: its usual trees do not exercise this short-tail case.
"""
import base64
import io
from pathlib import Path
import struct
import sys
import zipfile
import zlib


class Bits:
    def __init__(self):
        self.bits = []

    def write(self, value, width):
        self.bits.extend((value >> bit) & 1 for bit in range(width))

    def code(self, value, width):
        self.write(int(f'{value:0{width}b}'[::-1], 2), width)

    def bytes(self):
        return bytes(sum(self.bits[j] << (j % 8)
                         for j in range(i, min(i + 8, len(self.bits))))
                     for i in range(0, len(self.bits), 8))


def codes(lengths):
    result, code, previous = {}, 0, 0
    for length, symbol in sorted((n, s) for s, n in enumerate(lengths) if n):
        code <<= length - previous
        result[symbol] = (code, length)
        code += 1
        previous = length
    return result


def fixture():
    # Lengths 1..14,15,15 form a complete prefix tree. Its last literal '{'
    # and EOB have only 2+3 bits, while the decoder's lookahead asks for 15.
    lengths = [0] * 257
    lengths[65], lengths[123], lengths[256] = 1, 2, 3
    for symbol, length in enumerate(list(range(4, 15)) + [15, 15]):
        lengths[symbol] = length
    table = codes(lengths)
    bits = Bits()
    for value, width in [(1, 1), (2, 2), (0, 5), (0, 5), (15, 4)]:
        bits.write(value, width)  # final dynamic block; 257 literals, 1 distance
    order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    for symbol in order:
        bits.write(4 if symbol <= 15 else 0, 3)
    for length in lengths + [1]:
        bits.code(length, 4)  # complete 4-bit code-length tree; no RLE
    data = b'A' * 64 + b'{'
    for symbol in data:
        bits.code(*table[symbol])
    bits.code(*table[256])
    raw = bits.bytes()
    assert zlib.decompress(raw, -15) == data
    name, crc = b'tail.bin', zlib.crc32(data)
    local = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 8, 0, 33,
                        crc, len(raw), len(data), len(name), 0) + name + raw
    directory = struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 3 << 8 | 20,
                            20, 0, 8, 0, 33, crc, len(raw), len(data), len(name),
                            0, 0, 0, 0, 0o100644 << 16, 0) + name
    end = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, 1, 1,
                      len(directory), len(local), 0)
    result = local + directory + end
    assert zipfile.ZipFile(io.BytesIO(result)).read('tail.bin') == data
    return result


if __name__ == '__main__':
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name('dynamic_huffman_tail.zip.base64')
    payload = fixture()
    output.write_text(base64.b64encode(payload).decode('ascii') + '\n', encoding='ascii')
    print(f'{output.name}: {len(payload)} ZIP bytes; verified with zlib {zlib.ZLIB_RUNTIME_VERSION}')
