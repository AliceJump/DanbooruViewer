class SearchCompletionSuggestion {
  final String value;
  final String insertValue;
  final String source;
  final int score;
  final int? category;

  const SearchCompletionSuggestion({
    required this.value,
    required this.insertValue,
    required this.source,
    required this.score,
    this.category,
  });

  factory SearchCompletionSuggestion.fromJson(Map<String, dynamic> json) {
    return SearchCompletionSuggestion(
      value: json['value'] as String? ?? json['v'] as String? ?? '',
      insertValue:
          json['insert_value'] as String? ??
          json['i'] as String? ??
          json['value'] as String? ??
          json['v'] as String? ??
          '',
      source: json['source'] as String? ?? json['s'] as String? ?? '',
      score: json['score'] as int? ?? json['r'] as int? ?? 0,
      category: json['category'] as int? ?? json['c'] as int?,
    );
  }
}

class CompletionTagInfo {
  final String label;
  final int? category;

  const CompletionTagInfo({required this.label, this.category});
}
