import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/lanraragi_client.dart';
import 'settings_provider.dart';

/// Provides a LanraragiClient when settings are valid, otherwise null.
final lanraragiClientProvider = Provider<LanraragiClient?>((ref) {
  final settings = SettingsModel.instance;
  if (!settings.isValid) return null;
  return LanraragiClient(settings.serverUrl, settings.apiKey);
});
