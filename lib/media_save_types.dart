class MediaSaveResult {
  const MediaSaveResult({required this.destination, required this.isVideo});

  final String destination;
  final bool isVideo;
}

class MediaSaveException implements Exception {
  const MediaSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MediaSaveInput {
  const MediaSaveInput(this.stream, {this.length});

  final Stream<List<int>> stream;
  final int? length;
}
