import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/settings_provider.dart';

/// Immutable settings snapshot loaded from local storage.
class StoredSettingsData {
  /// Creates a stored settings payload.
  const StoredSettingsData({
    required this.serverUrl,
    required this.apiKey,
    required this.contentFolderPath,
    required this.nhentaiApiKey,
    required this.cropThumbnails,
    required this.librarySelectedCategoryId,
    required this.librarySortId,
    required this.librarySortOrder,
    required this.libraryNewOnly,
    required this.libraryUntaggedOnly,
    required this.libraryHideCompleted,
    required this.readerFitMode,
    required this.readerContinuousScroll,
    required this.readerRightToLeft,
    required this.readerAutoHideChrome,
    required this.readerZoomLevel,
    required this.readerFullscreen,
    required this.onDeckEntries,
    required this.useLocalOnDeckFallback,
  });

  /// Persisted LANraragi server URL.
  final String serverUrl;

  /// Persisted LANraragi API key loaded from secure storage.
  final String apiKey;

  /// Persisted LANraragi content folder path.
  final String contentFolderPath;

  /// Persisted nhentai API key loaded from shared preferences.
  final String nhentaiApiKey;

  /// Whether thumbnails should be cropped in grids.
  final bool cropThumbnails;

  /// Persisted selected library category ID.
  final String librarySelectedCategoryId;

  /// Persisted library sort option ID.
  final String librarySortId;

  /// Persisted library sort order.
  final String librarySortOrder;

  /// Whether the library new-only filter is enabled.
  final bool libraryNewOnly;

  /// Whether the library untagged-only filter is enabled.
  final bool libraryUntaggedOnly;

  /// Whether the library hide-completed filter is enabled.
  final bool libraryHideCompleted;

  /// Persisted reader fit mode name.
  final String readerFitMode;

  /// Whether continuous scrolling is enabled.
  final bool readerContinuousScroll;

  /// Whether right-to-left reading is enabled.
  final bool readerRightToLeft;

  /// Whether reader chrome auto-hide is enabled.
  final bool readerAutoHideChrome;

  /// Persisted reader zoom level.
  final double readerZoomLevel;

  /// Whether fullscreen preference is enabled.
  final bool readerFullscreen;

  /// Fallback On Deck entries cached locally.
  final List<OnDeckEntry> onDeckEntries;

  /// Whether the app should use locally stored On Deck data.
  final bool useLocalOnDeckFallback;
}

/// Persists app settings using shared preferences for non-sensitive values and
/// secure storage for the API key.
class SettingsStorageService {
  SettingsStorageService._();

  /// Singleton instance used by the settings provider.
  static final SettingsStorageService instance = SettingsStorageService._();

  static const _serverUrlKey = 'prefs_server_url';
  static const _legacyApiKeyKey = 'prefs_api_key';
  static const _secureApiKeyKey = 'secure_api_key';
  static const _contentFolderPathKey = 'contentFolderPath';
  static const _nhentaiApiKeyKey = 'nhentaiApiKey';
  static const _cropThumbnailsKey = 'prefs_crop_thumbnails';
  static const _librarySelectedCategoryIdKey =
      'prefs_library_selected_category_id';
  static const _librarySortIdKey = 'prefs_library_sort_id';
  static const _librarySortOrderKey = 'prefs_library_sort_order';
  static const _libraryNewOnlyKey = 'prefs_library_new_only';
  static const _libraryUntaggedOnlyKey = 'prefs_library_untagged_only';
  static const _libraryHideCompletedKey = 'prefs_library_hide_completed';
  static const _readerFitModeKey = 'prefs_reader_fit_mode';
  static const _readerContinuousScrollKey = 'prefs_reader_continuous_scroll';
  static const _readerRightToLeftKey = 'prefs_reader_right_to_left';
  static const _readerAutoHideChromeKey = 'prefs_reader_auto_hide_chrome';
  static const _readerZoomLevelKey = 'prefs_reader_zoom_level';
  static const _readerFullscreenKey = 'prefs_reader_fullscreen';
  static const _onDeckEntriesKey = 'prefs_on_deck_entries';
  static const _useLocalOnDeckFallbackKey =
      'prefs_use_local_on_deck_fallback';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Loads all persisted settings and migrates a legacy API key out of shared
  /// preferences when necessary.
  Future<StoredSettingsData> load() async {
    final sharedPreferences = await SharedPreferences.getInstance();
    final serverUrl = _normalizeServerUrl(
      sharedPreferences.getString(_serverUrlKey) ?? '',
    );
    final apiKey = await _loadApiKey(sharedPreferences);

    return StoredSettingsData(
      serverUrl: serverUrl,
      apiKey: apiKey,
      contentFolderPath:
          (sharedPreferences.getString(_contentFolderPathKey) ?? '').trim(),
      nhentaiApiKey:
          (sharedPreferences.getString(_nhentaiApiKeyKey) ?? '').trim(),
      cropThumbnails: sharedPreferences.getBool(_cropThumbnailsKey) ?? false,
      librarySelectedCategoryId:
          (sharedPreferences.getString(_librarySelectedCategoryIdKey) ?? '')
              .trim(),
      librarySortId:
          (sharedPreferences.getString(_librarySortIdKey) ?? 'title').trim(),
      librarySortOrder:
          (sharedPreferences.getString(_librarySortOrderKey) ?? 'asc').trim(),
      libraryNewOnly:
          sharedPreferences.getBool(_libraryNewOnlyKey) ?? false,
      libraryUntaggedOnly:
          sharedPreferences.getBool(_libraryUntaggedOnlyKey) ?? false,
      libraryHideCompleted:
          sharedPreferences.getBool(_libraryHideCompletedKey) ?? false,
      readerFitMode:
          (sharedPreferences.getString(_readerFitModeKey) ?? 'contain').trim(),
      readerContinuousScroll:
          sharedPreferences.getBool(_readerContinuousScrollKey) ?? false,
      readerRightToLeft:
          sharedPreferences.getBool(_readerRightToLeftKey) ?? false,
      readerAutoHideChrome:
          sharedPreferences.getBool(_readerAutoHideChromeKey) ?? true,
      readerZoomLevel:
          (sharedPreferences.getDouble(_readerZoomLevelKey) ?? 1.0),
      readerFullscreen:
          sharedPreferences.getBool(_readerFullscreenKey) ?? false,
      onDeckEntries: _readOnDeckEntries(
        sharedPreferences.getString(_onDeckEntriesKey),
      ),
      useLocalOnDeckFallback:
          sharedPreferences.getBool(_useLocalOnDeckFallbackKey) ?? false,
    );
  }

  /// Saves the LANraragi connection settings.
  Future<void> saveConnection({
    required String serverUrl,
    required String apiKey,
    required String contentFolderPath,
    required String nhentaiApiKey,
    required bool cropThumbnails,
  }) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setString(
      _serverUrlKey,
      _normalizeServerUrl(serverUrl),
    );
    await sharedPreferences.setBool(_cropThumbnailsKey, cropThumbnails);
    await sharedPreferences.setString(
      _contentFolderPathKey,
      contentFolderPath.trim(),
    );
    await sharedPreferences.setString(
      _nhentaiApiKeyKey,
      nhentaiApiKey.trim(),
    );
    await _secureStorage.write(key: _secureApiKeyKey, value: apiKey.trim());
    await sharedPreferences.remove(_legacyApiKeyKey);
  }

  /// Saves persisted library filter preferences.
  Future<void> saveLibraryPreferences({
    required String selectedCategoryId,
    required String sortId,
    required String sortOrder,
    required bool newOnly,
    required bool untaggedOnly,
    required bool hideCompleted,
  }) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setString(
      _librarySelectedCategoryIdKey,
      selectedCategoryId.trim(),
    );
    await sharedPreferences.setString(_librarySortIdKey, sortId.trim());
    await sharedPreferences.setString(
      _librarySortOrderKey,
      sortOrder.trim(),
    );
    await sharedPreferences.setBool(_libraryNewOnlyKey, newOnly);
    await sharedPreferences.setBool(_libraryUntaggedOnlyKey, untaggedOnly);
    await sharedPreferences.setBool(_libraryHideCompletedKey, hideCompleted);
  }

  /// Clears persisted library filter preferences.
  Future<void> clearLibraryPreferences() async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await Future.wait([
      sharedPreferences.remove(_librarySelectedCategoryIdKey),
      sharedPreferences.remove(_librarySortIdKey),
      sharedPreferences.remove(_librarySortOrderKey),
      sharedPreferences.remove(_libraryNewOnlyKey),
      sharedPreferences.remove(_libraryUntaggedOnlyKey),
      sharedPreferences.remove(_libraryHideCompletedKey),
    ]);
  }

  /// Saves persisted reader preferences.
  Future<void> saveReaderPreferences({
    required String fitMode,
    required bool continuousScroll,
    required bool rightToLeft,
    required bool autoHideChrome,
    required double zoomLevel,
    required bool fullscreen,
  }) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setString(_readerFitModeKey, fitMode.trim());
    await sharedPreferences.setBool(
      _readerContinuousScrollKey,
      continuousScroll,
    );
    await sharedPreferences.setBool(_readerRightToLeftKey, rightToLeft);
    await sharedPreferences.setBool(_readerAutoHideChromeKey, autoHideChrome);
    await sharedPreferences.setDouble(_readerZoomLevelKey, zoomLevel);
    await sharedPreferences.setBool(_readerFullscreenKey, fullscreen);
  }

  /// Saves fallback On Deck entries in shared preferences.
  Future<void> saveOnDeckEntries(List<OnDeckEntry> entries) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    final payload = jsonEncode(
      entries.map((entry) => entry.toJson()).toList(growable: false),
    );
    await sharedPreferences.setString(_onDeckEntriesKey, payload);
  }

  /// Saves whether local On Deck fallback should be used.
  Future<void> saveUseLocalOnDeckFallback(bool value) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setBool(_useLocalOnDeckFallbackKey, value);
  }

  /// Clears all persisted settings, including the secure API key.
  Future<void> clear() async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await Future.wait([
      sharedPreferences.remove(_serverUrlKey),
      sharedPreferences.remove(_legacyApiKeyKey),
      sharedPreferences.remove(_contentFolderPathKey),
      sharedPreferences.remove(_nhentaiApiKeyKey),
      sharedPreferences.remove(_cropThumbnailsKey),
      sharedPreferences.remove(_librarySelectedCategoryIdKey),
      sharedPreferences.remove(_librarySortIdKey),
      sharedPreferences.remove(_librarySortOrderKey),
      sharedPreferences.remove(_libraryNewOnlyKey),
      sharedPreferences.remove(_libraryUntaggedOnlyKey),
      sharedPreferences.remove(_libraryHideCompletedKey),
      sharedPreferences.remove(_readerFitModeKey),
      sharedPreferences.remove(_readerContinuousScrollKey),
      sharedPreferences.remove(_readerRightToLeftKey),
      sharedPreferences.remove(_readerAutoHideChromeKey),
      sharedPreferences.remove(_readerZoomLevelKey),
      sharedPreferences.remove(_readerFullscreenKey),
      sharedPreferences.remove(_onDeckEntriesKey),
      sharedPreferences.remove(_useLocalOnDeckFallbackKey),
      _secureStorage.delete(key: _secureApiKeyKey),
    ]);
  }

  Future<String> _loadApiKey(SharedPreferences sharedPreferences) async {
    final secureValue = (await _secureStorage.read(key: _secureApiKeyKey) ?? '')
        .trim();
    if (secureValue.isNotEmpty) {
      return secureValue;
    }

    final legacyValue =
        (sharedPreferences.getString(_legacyApiKeyKey) ?? '').trim();
    if (legacyValue.isEmpty) {
      return '';
    }

    await _secureStorage.write(key: _secureApiKeyKey, value: legacyValue);
    await sharedPreferences.remove(_legacyApiKeyKey);
    return legacyValue;
  }

  List<OnDeckEntry> _readOnDeckEntries(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! List) {
        return const [];
      }

      final entries = decoded
          .whereType<Map>()
          .map(
            (entry) =>
                OnDeckEntry.fromJson(Map<String, dynamic>.from(entry)),
          )
          .where(
            (entry) =>
                entry.archiveId.isNotEmpty &&
                entry.title.isNotEmpty &&
                !entry.isCompleted,
          )
          .toList(growable: true)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return List.unmodifiable(entries);
    } catch (_) {
      return const [];
    }
  }

  String _normalizeServerUrl(String value) {
    return value.trim().replaceAll(RegExp(r',[\s]*$'), '');
  }
}
