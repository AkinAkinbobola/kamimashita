import 'package:flutter/material.dart';

import '../api/lanraragi_client.dart';
import '../models/archive.dart';
import '../services/settings_storage_service.dart';

/// Local fallback entry for an in-progress archive.
class OnDeckEntry {
  /// Creates an On Deck entry.
  const OnDeckEntry({
    required this.archiveId,
    required this.title,
    required this.currentPage,
    required this.totalPages,
    required this.updatedAt,
  });

  /// Deserializes an entry from persisted JSON.
  factory OnDeckEntry.fromJson(Map<String, dynamic> json) {
    return OnDeckEntry(
      archiveId: json['archiveId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      currentPage: _parseInt(json['currentPage']) ?? 1,
      totalPages: _parseInt(json['totalPages']) ?? 1,
      updatedAt: _parseInt(json['updatedAt']) ?? 0,
    );
  }

  /// Creates an entry from an archive returned by LANraragi.
  factory OnDeckEntry.fromArchive(Archive archive) {
    final totalPages = archive.pageCount ?? 1;
    final currentPage = archive.progress?.clamp(1, totalPages) ?? 1;
    return OnDeckEntry(
      archiveId: archive.id,
      title: archive.title,
      currentPage: currentPage,
      totalPages: totalPages,
      updatedAt: archive.lastReadTime ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Archive identifier.
  final String archiveId;

  /// Archive title.
  final String title;

  /// Last read page.
  final int currentPage;

  /// Total number of pages.
  final int totalPages;

  /// Last update timestamp in milliseconds.
  final int updatedAt;

  /// Returns whether the entry is already complete.
  bool get isCompleted => totalPages > 0 && currentPage >= totalPages;

  /// Serializes the entry for persistence.
  Map<String, dynamic> toJson() => {
        'archiveId': archiveId,
        'title': title,
        'currentPage': currentPage,
        'totalPages': totalPages,
        'updatedAt': updatedAt,
      };

  static int? _parseInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }
}

/// Central app settings provider backed by shared preferences and secure
/// storage.
class SettingsModel extends ChangeNotifier {
  SettingsModel._internal() {
    _load();
  }

  /// Singleton instance used across the app.
  static final SettingsModel instance = SettingsModel._internal();

  /// Current LANraragi server URL.
  String serverUrl = '';

  /// Current LANraragi API key.
  String apiKey = '';

  /// Whether thumbnails should be cropped in the grid.
  bool cropThumbnails = false;

  /// Persisted reader fit mode.
  String readerFitMode = 'contain';

  /// Whether the reader uses continuous scrolling.
  bool readerContinuousScroll = false;

  /// Whether the reader uses right-to-left navigation.
  bool readerRightToLeft = false;

  /// Whether reader chrome should auto-hide.
  bool readerAutoHideChrome = true;

  /// Whether the reader should launch in fullscreen.
  bool readerFullscreen = false;

  /// Local fallback On Deck entries.
  List<OnDeckEntry> onDeckEntries = const [];

  /// Whether local On Deck fallback is currently enabled.
  bool useLocalOnDeckFallback = false;

  bool _isLoaded = false;

  /// Returns whether the provider has a usable connection config.
  bool get isValid => serverUrl.isNotEmpty && apiKey.isNotEmpty;

  /// Returns whether persisted settings have finished loading.
  bool get isLoaded => _isLoaded;

  /// Returns the LANraragi authorization header for the current API key.
  Map<String, String> authHeader() => isValid ? LanraragiClient.authorizationHeaders(apiKey) : {};

  Future<void> _load() async {
    try {
      final data = await SettingsStorageService.instance.load();
      serverUrl = data.serverUrl;
      apiKey = data.apiKey;
      cropThumbnails = data.cropThumbnails;
      readerFitMode = data.readerFitMode;
      readerContinuousScroll = data.readerContinuousScroll;
      readerRightToLeft = data.readerRightToLeft;
      readerAutoHideChrome = data.readerAutoHideChrome;
      readerFullscreen = data.readerFullscreen;
      onDeckEntries = data.onDeckEntries;
      useLocalOnDeckFallback = data.useLocalOnDeckFallback;
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  /// Updates persisted LANraragi connection settings.
  Future<void> update({
    String? serverUrl,
    String? apiKey,
    bool? cropThumbnails,
  }) async {
    if (serverUrl != null) {
      this.serverUrl = serverUrl.trim().replaceAll(RegExp(r',[\s]*$'), '');
    }
    if (apiKey != null) {
      this.apiKey = apiKey.trim();
    }
    if (cropThumbnails != null) {
      this.cropThumbnails = cropThumbnails;
    }

    notifyListeners();
    await SettingsStorageService.instance.saveConnection(
      serverUrl: this.serverUrl,
      apiKey: this.apiKey,
      cropThumbnails: this.cropThumbnails,
    );
  }

  /// Updates persisted reader preferences.
  Future<void> updateReaderPreferences({
    String? fitMode,
    bool? continuousScroll,
    bool? rightToLeft,
    bool? autoHideChrome,
    bool? fullscreen,
  }) async {
    if (fitMode != null) {
      readerFitMode = fitMode.trim();
    }
    if (continuousScroll != null) {
      readerContinuousScroll = continuousScroll;
    }
    if (rightToLeft != null) {
      readerRightToLeft = rightToLeft;
    }
    if (autoHideChrome != null) {
      readerAutoHideChrome = autoHideChrome;
    }
    if (fullscreen != null) {
      readerFullscreen = fullscreen;
    }

    notifyListeners();
    try {
      await SettingsStorageService.instance.saveReaderPreferences(
        fitMode: readerFitMode,
        continuousScroll: readerContinuousScroll,
        rightToLeft: readerRightToLeft,
        autoHideChrome: readerAutoHideChrome,
        fullscreen: readerFullscreen,
      );
    } catch (_) {
      // ignore
    }
  }

  /// Adds or updates a locally cached On Deck entry.
  Future<void> upsertOnDeckEntry({
    required String archiveId,
    required String title,
    required int currentPage,
    required int totalPages,
  }) async {
    final normalizedId = archiveId.trim();
    final normalizedTitle = title.trim();
    final normalizedTotalPages = totalPages <= 0 ? 1 : totalPages;
    final normalizedCurrentPage = currentPage.clamp(1, normalizedTotalPages);

    if (normalizedId.isEmpty || normalizedTitle.isEmpty) {
      return;
    }

    final nextEntries = onDeckEntries
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
    onDeckEntries = List.unmodifiable(nextEntries);
    notifyListeners();
    await _persistOnDeckEntries();
  }

  /// Removes a locally cached On Deck entry.
  Future<void> removeOnDeckEntry(String archiveId) async {
    final normalizedId = archiveId.trim();
    if (normalizedId.isEmpty) {
      return;
    }

    final nextEntries = onDeckEntries
        .where((entry) => entry.archiveId != normalizedId)
        .toList(growable: false);
    if (nextEntries.length == onDeckEntries.length) {
      return;
    }

    onDeckEntries = List.unmodifiable(nextEntries);
    notifyListeners();
    await _persistOnDeckEntries();
  }

  /// Persists whether the app should use local On Deck fallback data.
  Future<void> setUseLocalOnDeckFallback(bool value) async {
    if (useLocalOnDeckFallback == value) {
      return;
    }

    useLocalOnDeckFallback = value;
    notifyListeners();
    try {
      await SettingsStorageService.instance.saveUseLocalOnDeckFallback(value);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _persistOnDeckEntries() async {
    try {
      await SettingsStorageService.instance.saveOnDeckEntries(onDeckEntries);
    } catch (_) {
      // ignore
    }
  }

  /// Clears every persisted setting, including the secure API key.
  Future<void> clear() async {
    serverUrl = '';
    apiKey = '';
    cropThumbnails = false;
    readerFitMode = 'contain';
    readerContinuousScroll = false;
    readerRightToLeft = false;
    readerAutoHideChrome = true;
    readerFullscreen = false;
    onDeckEntries = const [];
    useLocalOnDeckFallback = false;
    notifyListeners();
    try {
      await SettingsStorageService.instance.clear();
    } catch (_) {
      // ignore
    }
  }
}
