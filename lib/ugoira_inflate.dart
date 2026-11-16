import 'package:archive/archive.dart';

/// Inflate directly into the caller's budgeted sink on native and web.
///
/// archive 4.7.1's Inflate.stream buffers a whole compressed block before
/// forwarding it to a non-memory sink. The lazy block API writes every
/// literal/back-reference to [output] instead, so limits stop allocation
/// inside a block, not after it. It also rejects an unfinished final block.
void inflateUgoiraStream(InputStream input, OutputStream output) {
  final inflater = Inflate.lazy(input, output: output);
  while (inflater.inflateBlock()) {}
}
