class Post {
  final int id;
  final String rating;
  final String tagString;
  final String? fileUrl;
  final String? largeFileUrl;
  final String? previewFileUrl;
  final String? tagStringGeneral;
  final String? tagStringArtist;
  final String? tagStringCharacter;
  final String? tagStringCopyright;
  final String? tagStringMeta;
  final String? source;

  Post({
    required this.id,
    required this.rating,
    required this.tagString,
    this.fileUrl,
    this.largeFileUrl,
    this.previewFileUrl,
    this.tagStringGeneral,
    this.tagStringArtist,
    this.tagStringCharacter,
    this.tagStringCopyright,
    this.tagStringMeta,
    this.source,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'],
      rating: json['rating'],
      tagString: json['tag_string'],
      fileUrl: json['file_url'],
      largeFileUrl: json['large_file_url'],
      previewFileUrl: json['preview_file_url'],
      tagStringGeneral: json['tag_string_general'],
      tagStringArtist: json['tag_string_artist'],
      tagStringCharacter: json['tag_string_character'],
      tagStringCopyright: json['tag_string_copyright'],
      tagStringMeta: json['tag_string_meta'],
      source: json['source'],
    );
  }
}
