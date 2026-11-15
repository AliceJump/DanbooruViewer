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
  final int? imageWidth;
  final int? imageHeight;

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
    this.imageWidth,
    this.imageHeight,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'],
      // Older local records can contain only an ID. Keep them accessible
      // without inventing a rating or discarding the user's collection.
      rating: json['rating'] as String? ?? '',
      tagString: json['tag_string'] as String? ?? '',
      fileUrl: json['file_url'],
      largeFileUrl: json['large_file_url'],
      previewFileUrl: json['preview_file_url'],
      tagStringGeneral: json['tag_string_general'],
      tagStringArtist: json['tag_string_artist'],
      tagStringCharacter: json['tag_string_character'],
      tagStringCopyright: json['tag_string_copyright'],
      tagStringMeta: json['tag_string_meta'],
      source: json['source'],
      imageWidth: json['image_width'],
      imageHeight: json['image_height'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'rating': rating,
      'tag_string': tagString,
      'file_url': fileUrl,
      'large_file_url': largeFileUrl,
      'preview_file_url': previewFileUrl,
      'tag_string_general': tagStringGeneral,
      'tag_string_artist': tagStringArtist,
      'tag_string_character': tagStringCharacter,
      'tag_string_copyright': tagStringCopyright,
      'tag_string_meta': tagStringMeta,
      'source': source,
      'image_width': imageWidth,
      'image_height': imageHeight,
    };
  }
}
