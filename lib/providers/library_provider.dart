import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/archive.dart';
import '../utils/archive_thumbnail_url.dart';
import 'settings_provider.dart';

/// Invalidating this provider triggers the library screen to reload data.
final libraryProvider = Provider<Object>((ref) => Object());

final libraryStateProvider = Provider<LibraryState>((ref) {
  return LibraryState.instance;
});

class LibraryState extends ChangeNotifier {
  LibraryState._();

  static final LibraryState instance = LibraryState._();

  List<Archive> _items = const [];
  List<OnDeckEntry> _onDeckEntries = const [];
  int? _lastKnownArchiveCount;
  final Set<String> _missingThumbnailArchiveIds = <String>{};
  final Map<String, int> _thumbnailRetryTimestamps = <String, int>{};

  List<Archive> get items => _items;
  List<OnDeckEntry> get onDeckEntries => _onDeckEntries;
  int? get lastKnownArchiveCount => _lastKnownArchiveCount;
  Set<String> get missingThumbnailArchiveIds =>
      Set.unmodifiable(_missingThumbnailArchiveIds);

  bool hasMissingThumbnail(String archiveId) {
    return _missingThumbnailArchiveIds.contains(archiveId.trim());
  }

  int? thumbnailRetryTimestamp(String archiveId) {
    return _thumbnailRetryTimestamps[archiveId.trim()];
  }

  List<ArchiveImageSource> resolveArchiveImageSources(
    String serverUrl,
    Archive archive,
  ) {
    return buildArchiveImageSources(
      serverUrl,
      archive,
      retryTimestamp: thumbnailRetryTimestamp(archive.id),
    );
  }

  ArchiveImageSource? primaryArchiveThumbnailSource(
    String serverUrl,
    Archive archive,
  ) {
    return buildPrimaryArchiveThumbnailSource(
      serverUrl,
      archive,
      retryTimestamp: thumbnailRetryTimestamp(archive.id),
    );
  }

  void setItems(List<Archive> items, {int? archiveCount}) {
    _items = List.unmodifiable(items);
    _lastKnownArchiveCount = archiveCount ?? _lastKnownArchiveCount;
    notifyListeners();
  }

  void clearItems() {
    if (_items.isEmpty) {
      return;
    }
    _items = const [];
    _lastKnownArchiveCount = null;
    notifyListeners();
  }

  void updateArchiveProgress(String archiveId, int progress) {
    var changed = false;
    final nextItems = _items
        .map((archive) {
          if (archive.id != archiveId || archive.progress == progress) {
            return archive;
          }
          changed = true;
          return archive.copyWith(progress: progress);
        })
        .toList(growable: false);
    if (!changed) {
      return;
    }
    _items = List.unmodifiable(nextItems);
    notifyListeners();
  }

  void markThumbnailMissing(String archiveId) {
    final normalizedArchiveId = archiveId.trim();
    if (normalizedArchiveId.isEmpty) {
      return;
    }

    _missingThumbnailArchiveIds.add(normalizedArchiveId);
    _thumbnailRetryTimestamps[normalizedArchiveId] =
        DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  void clearThumbnailMissing(String archiveId) {
    final normalizedArchiveId = archiveId.trim();
    if (normalizedArchiveId.isEmpty) {
      return;
    }

    final removedMissing = _missingThumbnailArchiveIds.remove(
      normalizedArchiveId,
    );
    final removedTimestamp =
        _thumbnailRetryTimestamps.remove(normalizedArchiveId) != null;
    if (!removedMissing && !removedTimestamp) {
      return;
    }
    notifyListeners();
  }

  void bumpMissingThumbnailRetryTimestamps(Iterable<Archive> archives) {
    final candidates = archives
        .where((archive) {
          final hasNoCoverUrl =
              archive.coverUrl == null || archive.coverUrl!.trim().isEmpty;
          return hasNoCoverUrl || hasMissingThumbnail(archive.id);
        })
        .toList(growable: false);

    if (candidates.isEmpty) {
      return;
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final archive in candidates) {
      final archiveId = archive.id.trim();
      if (archiveId.isEmpty) {
        continue;
      }
      _thumbnailRetryTimestamps[archiveId] = timestamp;
    }
    notifyListeners();
  }

  void clearThumbnailState() {
    if (_missingThumbnailArchiveIds.isEmpty &&
        _thumbnailRetryTimestamps.isEmpty) {
      return;
    }
    _missingThumbnailArchiveIds.clear();
    _thumbnailRetryTimestamps.clear();
    notifyListeners();
  }

  void setOnDeckEntries(List<OnDeckEntry> entries) {
    _onDeckEntries = List.unmodifiable(entries);
    notifyListeners();
  }

  void clearOnDeckEntries() {
    if (_onDeckEntries.isEmpty) {
      return;
    }
    _onDeckEntries = const [];
    notifyListeners();
  }

  void upsertOnDeckEntry({
    required String archiveId,
    required String title,
    required int currentPage,
    required int totalPages,
  }) {
    final normalizedId = archiveId.trim();
    final normalizedTitle = title.trim();
    final normalizedTotalPages = totalPages <= 0 ? 1 : totalPages;
    final normalizedCurrentPage = currentPage.clamp(1, normalizedTotalPages);

    if (normalizedId.isEmpty || normalizedTitle.isEmpty) {
      return;
    }

    final nextEntries = _onDeckEntries
        .where((entry) => entry.archiveId != normalizedId)
        .toList(growable: true);

    if (normalizedCurrentPage < normalizedTotalPages) {
      nextEntries.add(
        OnDeckEntry(
          archiveId: normalizedId,
          title: normalizedTitle,
          currentPage: normalizedCurrentPage,
          totalPages: normalizedTotalPages,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    nextEntries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _onDeckEntries = List.unmodifiable(nextEntries);
    notifyListeners();
  }
}
