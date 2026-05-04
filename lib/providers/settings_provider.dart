import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted application settings (server URL and base64 API key).
class SettingsModel extends ChangeNotifier {
  SettingsModel._internal() {
    _load();
  }

  static final SettingsModel instance = SettingsModel._internal();

  String serverUrl = '';
  String apiKey = '';

  bool get isValid => serverUrl.isNotEmpty && apiKey.isNotEmpty;

  Map<String, String> authHeader() => isValid ? {'Authorization': 'Bearer $apiKey'} : {};

  static const _kServerUrl = 'prefs_server_url';
  static const _kApiKey = 'prefs_api_key';

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      serverUrl = sp.getString(_kServerUrl) ?? '';
      apiKey = sp.getString(_kApiKey) ?? '';
      notifyListeners();
    } catch (e) {
      // ignore
    }
  }

  Future<void> update({String? serverUrl, String? apiKey}) async {
    if (serverUrl != null) this.serverUrl = serverUrl;
    if (apiKey != null) this.apiKey = apiKey;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kServerUrl, this.serverUrl);
      await sp.setString(_kApiKey, this.apiKey);
    } catch (e) {
      // ignore
    }
  }

  Future<void> clear() async {
    serverUrl = '';
    apiKey = '';
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kServerUrl);
      await sp.remove(_kApiKey);
    } catch (e) {}
  }
}

