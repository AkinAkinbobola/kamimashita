import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/lanraragi_client.dart';

/// Persisted application settings (server URL and base64 API key).
class SettingsModel extends ChangeNotifier {
  SettingsModel._internal() {
    _load();
  }

  static final SettingsModel instance = SettingsModel._internal();

  String serverUrl = '';
  String apiKey = '';
  bool cropThumbnails = false;

  bool get isValid => serverUrl.isNotEmpty && apiKey.isNotEmpty;

  Map<String, String> authHeader() => isValid ? {'Authorization': 'Bearer ${LanraragiClient.normalizeApiKey(apiKey)}'} : {};

  static const _kServerUrl = 'prefs_server_url';
  static const _kApiKey = 'prefs_api_key';
  static const _kCropThumbnails = 'prefs_crop_thumbnails';

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      serverUrl = (sp.getString(_kServerUrl) ?? '').trim();
      // Remove accidental trailing commas or spaces
      serverUrl = serverUrl.replaceAll(RegExp(r',[\s]*$'), '');
      apiKey = (sp.getString(_kApiKey) ?? '').trim();
      cropThumbnails = sp.getBool(_kCropThumbnails) ?? false;
      notifyListeners();
    } catch (e) {
      // ignore
    }
  }

  Future<void> update({String? serverUrl, String? apiKey, bool? cropThumbnails}) async {
    if (serverUrl != null) this.serverUrl = serverUrl.trim().replaceAll(RegExp(r',[\s]*$'), '');
    if (apiKey != null) this.apiKey = apiKey.trim();
    if (cropThumbnails != null) this.cropThumbnails = cropThumbnails;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kServerUrl, this.serverUrl);
      await sp.setString(_kApiKey, this.apiKey);
      await sp.setBool(_kCropThumbnails, this.cropThumbnails);
    } catch (e) {
      // ignore
    }
  }

  Future<void> clear() async {
    serverUrl = '';
    apiKey = '';
    cropThumbnails = false;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kServerUrl);
      await sp.remove(_kApiKey);
      await sp.remove(_kCropThumbnails);
    } catch (e) {
      // ignore
    }
  }
}

