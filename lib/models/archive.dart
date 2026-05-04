class Archive {
  Archive({
    required this.id,
    required this.title,
    this.coverUrl,
    this.year,
    this.pageCount,
  });

  final String id;
  final String title;
  final String? coverUrl;
  final int? year;
  final int? pageCount;

  factory Archive.fromJson(Map<String, dynamic> json) {
    // Try common keys used by various LRR responses
    String id = '';
    if (json.containsKey('id')) id = json['id'].toString();
    if (json.containsKey('archiveid')) id = json['archiveid'].toString();
    if (json.containsKey('ArchiveID')) id = json['ArchiveID'].toString();

    String title = json['title']?.toString() ?? json['Name']?.toString() ?? '';

    String? cover;
    if (json.containsKey('cover')) cover = json['cover']?.toString();
    if ((cover == null || cover.isEmpty) && json.containsKey('thumb')) cover = json['thumb']?.toString();
    if ((cover == null || cover.isEmpty) && json.containsKey('coverurl')) cover = json['coverurl']?.toString();

    int? pageCount;
    if (json.containsKey('pages')) {
      final p = json['pages'];
      if (p is int) pageCount = p;
      if (p is String) pageCount = int.tryParse(p);
      if (p is List) pageCount = p.length;
    }

    int? year;
    if (json.containsKey('year')) year = int.tryParse(json['year']?.toString() ?? '');

    return Archive(id: id, title: title, coverUrl: cover, year: year, pageCount: pageCount);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cover': coverUrl,
        'year': year,
        'pages': pageCount,
      };
}
