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
    required this.cropThumbnails,
    required this.readerFitMode,
    required this.readerContinuousScroll,
    required this.readerRightToLeft,
    required this.readerAutoHideChrome,
    required this.readerFullscreen,
    required this.onDeckEntries,
    required this.useLocalOnDeckFallback,
  });

  /// Persisted LANraragi server URL.
  final String serverUrl;

  /// Persisted LANraragi API key loaded from secure storage.
  final String apiKey;

  /// Whether thumbnails should be cropped in grids.
  final bool cropThumbnails;

  /// Persisted reader fit mode name.
  final String readerFitMode;

  /// Whether continuous scrolling is enabled.
  final bool readerContinuousScroll;

  /// Whether right-to-left reading is enabled.
  final bool readerRightToLeft;

  /// Whether reader chrome auto-hide is enabled.
  final bool readerAutoHideChrome;

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
  static const _cropThumbnailsKey = 'prefs_crop_thumbnails';
  static const _readerFitModeKey = 'prefs_reader_fit_mode';
  static const _readerContinuousScrollKey = 'prefs_reader_continuous_scroll';
  static const _readerRightToLeftKey = 'prefs_reader_right_to_left';
  static const _readerAutoHideChromeKey = 'prefs_reader_auto_hide_chrome';
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
      cropThumbnails:
          sharedPreferences.getBool(_cropThumbnailsKey) ?? false,
      readerFitMode:
          (sharedPreferences.getString(_readerFitModeKey) ?? 'contain').trim(),
      readerContinuousScroll:
          sharedPreferences.getBool(_readerContinuousScrollKey) ?? false,
      readerRightToLeft:
          sharedPreferences.getBool(_readerRightToLeftKey) ?? false,
      readerAutoHideChrome:
          sharedPreferences.getBool(_readerAutoHideChromeKey) ?? true,
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
    required bool cropThumbnails,
  }) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    await sharedPreferences.setString(
      _serverUrlKey,
      _normalizeServerUrl(serverUrl),
    );
    await sharedPreferences.setBool(_cropThumbnailsKey, cropThumbnails);
    await _secureStorage.write(key: _secureApiKeyKey, value: apiKey.trim());
    await sharedPreferences.remove(_legacyApiKeyKey);
  }

  /// Saves persisted reader preferences.
  Future<void> saveReaderPreferences({
    required String fitMode,
    required bool continuousScroll,
    required bool rightToLeft,
    required bool autoHideChrome,
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
      sharedPreferences.remove(_cropThumbnailsKey),
      sharedPreferences.remove(_readerFitModeKey),
      sharedPreferences.remove(_readerContinuousScrollKey),
      sharedPreferences.remove(_readerRightToLeftKey),
      sharedPreferences.remove(_readerAutoHideChromeKey),
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