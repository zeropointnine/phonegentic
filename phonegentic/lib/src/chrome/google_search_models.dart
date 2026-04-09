class GoogleSearchResultItem {
  final String title;
  final String url;
  final String snippet;

  const GoogleSearchResultItem({
    this.title = '',
    this.url = '',
    this.snippet = '',
  });

  factory GoogleSearchResultItem.fromMap(Map<String, dynamic> map) {
    return GoogleSearchResultItem(
      title: map['title'] as String? ?? '',
      url: map['url'] as String? ?? '',
      snippet: map['snippet'] as String? ?? '',
    );
  }

  bool get hasContent => title.isNotEmpty || snippet.isNotEmpty;

  @override
  String toString() => 'GoogleSearchResultItem(title: $title, url: $url)';
}

class GoogleSearchResult {
  final String query;
  final List<GoogleSearchResultItem> items;
  final DateTime lastUpdated;

  const GoogleSearchResult({
    required this.query,
    required this.items,
    required this.lastUpdated,
  });
}
