import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted application settings (server URL and base64 API key).
@immutable
class Settings {
  const Settings({this.serverUrl = '', this.apiKey = ''});

  final String serverUrl;
  final String apiKey; // expected to be base64-encoded string

  bool get isValid => serverUrl.isNotEmpty && apiKey.isNotEmpty;

  Settings copyWith({String? serverUrl, String? apiKey}) {
    return Settings(
      serverUrl: serverUrl ?? this.serverUrl,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  Map<String, String> authHeader() {
    if (apiKey.isEmpty) return {};
    return {'Authorization': 'Bearer $apiKey'};
  }
}

const _kServerUrl = 'prefs_server_url';
const _kApiKey = 'prefs_api_key';

/// StateNotifier that loads/saves Settings to SharedPreferences.
class SettingsNotifier extends StateNotifier<Settings> {
  SettingsNotifier() : super(const Settings()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final url = sp.getString(_kServerUrl) ?? '';
      final api = sp.getString(_kApiKey) ?? '';
      state = state.copyWith(serverUrl: url, apiKey: api);
    } catch (e) {
      // ignore errors, keep defaults
      if (kDebugMode) {
        // ignore: avoid_print
        print('Failed to load settings: $e');
      }
    }
  }

  Future<void> update({String? serverUrl, String? apiKey}) async {
    state = state.copyWith(serverUrl: serverUrl, apiKey: apiKey);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kServerUrl, state.serverUrl);
      await sp.setString(_kApiKey, state.apiKey);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Failed to save settings: $e');
      }
    }
  }

  Future<void> clear() async {
    state = const Settings();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kServerUrl);
      await sp.remove(_kApiKey);
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('Failed to clear settings: $e');
      }
    }
  }
}

/// Public Riverpod provider for settings.
final settingsProvider = StateNotifierProvider<SettingsNotifier, Settings>((ref) {
  return SettingsNotifier();
});
