import 'completion_case_mapping.dart';

/// The binary index uses a fixed Unicode 15.0 simple lowercase mapping.
///
/// The Python builder and Dart use the same checked-in mapping. Neither the
/// runtime's Unicode version nor JS's contextual sigma/dotted-I expansion can
/// change a key. The generated table is compiled into the app, not loaded as
/// an asset when search starts.
/// This does not strip accents, fold final sigma, or normalize Unicode forms.
String normalizeCompletionKey(String value) {
  var ascii = true;
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) > 0x7f) {
      ascii = false;
      break;
    }
  }
  if (ascii) return value.toLowerCase();

  final result = StringBuffer();
  for (final scalar in value.runes) {
    result.writeCharCode(_lowercaseScalar(scalar));
  }
  return result.toString();
}

int _lowercaseScalar(int scalar) {
  if (scalar < 0x80) {
    return scalar >= 0x41 && scalar <= 0x5a ? scalar + 0x20 : scalar;
  }
  var low = 0;
  var high = completionLowercaseRanges.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    final (start, end, step, delta) = completionLowercaseRanges[middle];
    if (scalar < start) {
      high = middle;
    } else if (scalar > end) {
      low = middle + 1;
    } else {
      return (scalar - start) % step == 0 ? scalar + delta : scalar;
    }
  }
  return scalar;
}
