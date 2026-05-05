class Archive {
  Archive({
    required this.id,
    required this.title,
    this.coverUrl,
    this.filename,
    this.sourceUrl,
    this.tags,
    this.progress,
    this.lastReadTime,
    this.isNew,
    this.year,
    this.pageCount,
  });

  final String id;
  final String title;
  final String? coverUrl;
  final String? filename;
  final String? sourceUrl;
  final String? tags;
  final int? progress;
  final int? lastReadTime;
  final bool? isNew;
  final int? year;
  final int? pageCount;

  bool get isCompleted {
    final currentProgress = progress;
    final totalPages = pageCount;
    if (currentProgress == null || totalPages == null || totalPages <= 0) {
      return false;
    }
    return currentProgress >= totalPages;
  }

  String? thumbnailUrl(String serverUrl) {
    final normalizedServerUrl = serverUrl.trim().replaceAll(
      RegExp(r',\s*$'),
      '',
    );
    final archiveId = id.trim();
    if (normalizedServerUrl.isEmpty || archiveId.isEmpty) {
      return null;
    }

    var normalizedBase = normalizedServerUrl;
    if (normalizedBase.endsWith('/')) {
      normalizedBase = normalizedBase.substring(0, normalizedBase.length - 1);
    }
    if (normalizedBase.toLowerCase().endsWith('/api')) {
      normalizedBase = normalizedBase.substring(0, normalizedBase.length - 4);
    }

    return '$normalizedBase/api/archives/$archiveId/thumbnail';
  }

  List<String> get parsedTags {
    final raw = tags;
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }

    return raw
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
  }

  Archive copyWith({
    String? id,
    String? title,
    String? coverUrl,
    String? filename,
    String? sourceUrl,
    String? tags,
    int? progress,
    int? lastReadTime,
    bool? isNew,
    int? year,
    int? pageCount,
  }) {
    return Archive(
      id: id ?? this.id,
      title: title ?? this.title,
      coverUrl: coverUrl ?? this.coverUrl,
      filename: filename ?? this.filename,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      tags: tags ?? this.tags,
      progress: progress ?? this.progress,
      lastReadTime: lastReadTime ?? this.lastReadTime,
      isNew: isNew ?? this.isNew,
      year: year ?? this.year,
      pageCount: pageCount ?? this.pageCount,
    );
  }

  factory Archive.fromJson(Map<String, dynamic> json) {
    // Try common keys used by various LRR responses
    String id = '';
    if (json.containsKey('id')) id = json['id'].toString();
    if (json.containsKey('archiveid')) id = json['archiveid'].toString();
    if (json.containsKey('ArchiveID')) id = json['ArchiveID'].toString();
    if (json.containsKey('arcid')) id = json['arcid'].toString();

    String title =
        json['title']?.toString() ??
        json['Name']?.toString() ??
        json['filename']?.toString() ??
        '';

    String? cover;
    if (json.containsKey('cover')) {
      cover = json['cover']?.toString();
    }
    if ((cover == null || cover.isEmpty) && json.containsKey('thumb')) {
      cover = json['thumb']?.toString();
    }
    if ((cover == null || cover.isEmpty) && json.containsKey('coverurl')) {
      cover = json['coverurl']?.toString();
    }

    String? filename;
    if (json.containsKey('filename')) {
      filename = json['filename']?.toString();
    }
    if ((filename == null || filename.isEmpty) &&
        json.containsKey('Filename')) {
      filename = json['Filename']?.toString();
    }

    String? sourceUrl;
    for (final key in const [
      'source',
      'source_url',
      'sourceurl',
      'url',
      'link',
    ]) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        sourceUrl = value;
        break;
      }
    }

    String? tags;
    if (json.containsKey('tags')) {
      tags = json['tags']?.toString();
    }
    if ((tags == null || tags.isEmpty) && json.containsKey('Tags')) {
      tags = json['Tags']?.toString();
    }
    if ((sourceUrl == null || sourceUrl.isEmpty) && tags != null) {
      for (final rawTag in tags.split(',')) {
        final tag = rawTag.trim();
        if (!tag.toLowerCase().startsWith('source:')) {
          continue;
        }
        final candidate = tag.substring('source:'.length).trim();
        if (candidate.isNotEmpty) {
          sourceUrl = candidate;
          break;
        }
      }
    }

    int? progress;
    if (json.containsKey('progress')) {
      final p = json['progress'];
      if (p is int) progress = p;
      if (p is String) progress = int.tryParse(p);
    }

    int? lastReadTime;
    if (json.containsKey('lastreadtime')) {
      final lastRead = json['lastreadtime'];
      if (lastRead is int) lastReadTime = lastRead;
      if (lastRead is String) lastReadTime = int.tryParse(lastRead);
    }

    bool? isNew;
    if (json.containsKey('isnew')) {
      final rawIsNew = json['isnew'];
      if (rawIsNew is bool) isNew = rawIsNew;
      if (rawIsNew is int) isNew = rawIsNew != 0;
      if (rawIsNew is String) {
        final normalized = rawIsNew.toLowerCase();
        if (normalized == 'true' || normalized == '1') isNew = true;
        if (normalized == 'false' || normalized == '0') isNew = false;
      }
    }

    int? pageCount;
    if (json.containsKey('pages')) {
      final p = json['pages'];
      if (p is int) pageCount = p;
      if (p is String) pageCount = int.tryParse(p);
      if (p is List) pageCount = p.length;
    }
    if (json.containsKey('pagecount')) {
      final p = json['pagecount'];
      if (p is int) pageCount = p;
      if (p is String) pageCount = int.tryParse(p);
    }

    int? year;
    if (json.containsKey('year')) {
      year = int.tryParse(json['year']?.toString() ?? '');
    }

    return Archive(
      id: id,
      title: title,
      coverUrl: cover,
      filename: filename,
      sourceUrl: sourceUrl,
      tags: tags,
      progress: progress,
      lastReadTime: lastReadTime,
      isNew: isNew,
      year: year,
      pageCount: pageCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': coverUrl,
    'filename': filename,
    'source': sourceUrl,
    'tags': tags,
    'progress': progress,
    'lastreadtime': lastReadTime,
    'isnew': isNew,
    'year': year,
    'pages': pageCount,
  };
}
