import 'package:flutter/foundation.dart';

import 'network/network_errors.dart';
import 'ugoira_codec.dart';

Future<Uint8List> convertUgoiraBytesToGif(
  Uint8List bytes, {
  NetworkCancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final gif = await compute(mergeUgoiraBytesToGifSync, bytes);
  cancelToken?.throwIfCancelled();
  return gif;
}
