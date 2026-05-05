import '../models/archive.dart';

class ArchiveImageSource {
  const ArchiveImageSource({required this.url, required this.cacheKey});

  final String url;
  final String cacheKey;
}

List<ArchiveImageSource> buildArchiveImageSources(
  String serverUrl,
  Archive archive, {
  int? retryTimestamp,
}) {
  if (serverUrl.isEmpty || archive.id.isEmpty) {
    return const [];
  }

  final normalizedBase = normalizeArchiveThumbnailBase(serverUrl);
  final thumbnailUrl = withArchiveThumbnailRetryTimestamp(
    '$normalizedBase/api/archives/${archive.id}/thumbnail',
    retryTimestamp,
  );
  final sources = <ArchiveImageSource>[
    ArchiveImageSource(
      url: thumbnailUrl,
      cacheKey: withArchiveThumbnailRetryCacheKey(
        'archive-thumbnail-${archive.id}',
        retryTimestamp,
      ),
    ),
  ];

  final coverUrl = resolveArchiveCoverUrl(normalizedBase, archive.coverUrl);
  if (coverUrl != null && coverUrl.isNotEmpty && coverUrl != thumbnailUrl) {
    sources.add(
      ArchiveImageSource(
        url: coverUrl,
        cacheKey: 'archive-cover-${archive.id}',
      ),
    );
  }

  return List.unmodifiable(sources);
}

ArchiveImageSource? buildPrimaryArchiveThumbnailSource(
  String serverUrl,
  Archive archive, {
  int? retryTimestamp,
}) {
  final sources = buildArchiveImageSources(
    serverUrl,
    archive,
    retryTimestamp: retryTimestamp,
  );
  if (sources.isEmpty) {
    return null;
  }
  return sources.first;
}

String? resolveArchiveCoverUrl(String normalizedBase, String? rawCoverUrl) {
  final cover = rawCoverUrl?.trim();
  if (cover == null || cover.isEmpty) {
    return null;
  }

  if (cover.startsWith('http://') || cover.startsWith('https://')) {
    return cover;
  }
  if (cover.startsWith('/')) {
    return '$normalizedBase$cover';
  }
  return '$normalizedBase/${cover.replaceFirst(RegExp(r'^/+'), '')}';
}

String normalizeArchiveThumbnailBase(String value) {
  var normalized = value.trim().replaceAll(RegExp(r',\s*$'), '');
  if (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.toLowerCase().endsWith('/api')) {
    normalized = normalized.substring(0, normalized.length - 4);
  }
  return normalized;
}

String archiveThumbnailCacheIdentity(String serverUrl, String archiveId) {
  return '${normalizeArchiveThumbnailBase(serverUrl)}|$archiveId';
}

String withArchiveThumbnailRetryTimestamp(String url, int? retryTimestamp) {
  if (retryTimestamp == null) {
    return url;
  }

  final separator = url.contains('?') ? '&' : '?';
  return '$url${separator}t=$retryTimestamp';
}

String withArchiveThumbnailRetryCacheKey(String cacheKey, int? retryTimestamp) {
  if (retryTimestamp == null) {
    return cacheKey;
  }
  return '$cacheKey-$retryTimestamp';
}
