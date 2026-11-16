/// Media URLs can carry signed query strings; only the path identifies a file.
bool isVideoUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return const ['.mp4', '.webm', '.mov', '.m4v'].any(path.endsWith);
}

Uri? remoteMediaUri(String source) {
  final uri = Uri.tryParse(source.trim());
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}
