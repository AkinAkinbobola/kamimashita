import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/archive.dart';
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

  List<Archive> get items => _items;
  List<OnDeckEntry> get onDeckEntries => _onDeckEntries;

  void setItems(List<Archive> items) {
    _items = List.unmodifiable(items);
    notifyListeners();
  }

  void clearItems() {
    if (_items.isEmpty) {
      return;
    }
    _items = const [];
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
