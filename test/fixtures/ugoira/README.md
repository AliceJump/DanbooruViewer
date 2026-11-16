# Dynamic Huffman tail fixture

`dynamic_huffman_tail.zip.base64` encodes a 261-byte ZIP containing `tail.bin`
with 64 ASCII `A` bytes followed by `{` (65 uncompressed bytes). Base64 keeps
this small fixture as ordinary Git text instead of an LFS object.

The generator constructs an independent, valid DEFLATE dynamic block. Its
complete literal tree has code lengths `1, 2, ..., 14, 15, 15`: `A` has length 1,
`{` has length 2, and EOB has length 3. The final literal and EOB therefore need
fewer bits than the tree's maximum 15-bit lookahead. This exercises a case the
ordinary optimizing compressor need not generate.

The fixture does **not** use Dart's `archive` encoder. The generator verifies
the raw DEFLATE stream with Python's standard `zlib.decompress(raw, -15)` and
the complete ZIP with `zipfile.ZipFile.read`. It was generated and independently
validated with zlib 1.3.2.

To reproduce it:

```sh
python test/fixtures/ugoira/generate_dynamic_huffman_tail.py
```

The ZIP timestamps, metadata, tree and content are fixed. The Flutter regression
checks all decoded bytes, output-budget enforcement, CRC/length validation and
the original compressed-data range. No generator is required to run the tests.
