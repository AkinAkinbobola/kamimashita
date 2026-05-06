import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/lanraragi_client.dart';
import '../providers/settings_provider.dart';
import '../utils/app_strings.dart';
import '../widgets/theme.dart';
import '../widgets/window_controls.dart';

/// Screen for configuring the LANraragi connection settings.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  bool _isSaving = false;
  bool _isTesting = false;
  String? _statusText;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    final s = SettingsModel.instance;
    _urlController.text = s.serverUrl;
    _apiController.text = s.apiKey;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isConnected = await _runConnectionCheck(showSuccess: false);
    if (!isConnected) {
      return;
    }

    final serverUrl = _urlController.text.trim();
    final apiKey = _apiController.text.trim();
    setState(() {
      _isSaving = true;
      _statusText = null;
    });

    try {
      await SettingsModel.instance.update(serverUrl: serverUrl, apiKey: apiKey);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<bool> _runConnectionCheck({required bool showSuccess}) async {
    final serverUrl = _urlController.text.trim();
    final apiKey = _apiController.text.trim();
    setState(() {
      _isTesting = true;
      _statusText = null;
    });

    try {
      final client = LanraragiClient(serverUrl, apiKey);
      await client.getServerInfo();
      if (mounted && showSuccess) {
        setState(() {
          _statusText = AppStrings.connectionSuccessful;
          _statusIsError = false;
        });
      }
      return true;
    } on LanraragiException catch (e) {
      if (mounted) {
        setState(() {
          _statusText = e.message;
          _statusIsError = true;
        });
      }
      return false;
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusText = AppStrings.connectionFailed;
          _statusIsError = true;
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  InputDecoration _fieldDecoration({required String hintText}) {
    return InputDecoration(
      hintText: hintText,
      filled: true,
      fillColor: const Color(0xFF1A1A1A),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2A2E39), width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2A2E39), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppTheme.crimson, width: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusIsError
        ? theme.colorScheme.error
        : AppTheme.crimson;

    return Scaffold(
      body: Column(
        children: [
          _SettingsTopBar(
            onBackPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceRaised,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: const Color(0xFF26222A),
                        width: 1,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppStrings.settingsSectionTitle,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            AppStrings.settingsDescription,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 22),
                          Text(
                            AppStrings.serverUrlLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white70,
                              fontSize: 11,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _urlController,
                            decoration: _fieldDecoration(
                              hintText: AppStrings.serverUrlHint,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            AppStrings.apiKeyLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white70,
                              fontSize: 11,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _apiController,
                            decoration: _fieldDecoration(
                              hintText: AppStrings.apiKeyHint,
                            ),
                            obscureText: true,
                          ),
                          const SizedBox(height: 18),
                          OutlinedButton(
                            onPressed: (_isTesting || _isSaving)
                                ? null
                                : () => _runConnectionCheck(showSuccess: true),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Color(0xFF2A2E39)),
                              backgroundColor: const Color(0xFF1A1A1A),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              _isTesting
                                  ? AppStrings.testingConnection
                                  : AppStrings.testConnection,
                            ),
                          ),
                          if (_statusText != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: statusColor.withValues(alpha: 0.35),
                                ),
                              ),
                              child: SelectableText(
                                _statusText!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: _isSaving
                                    ? null
                                    : () => Navigator.of(context).pop(),
                                child: const Text(AppStrings.cancel),
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton(
                                onPressed:
                                    (_isSaving || _isTesting) ? null : _save,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.crimson,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  _isSaving
                                      ? AppStrings.saving
                                      : AppStrings.save,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar({required this.onBackPressed});

  final VoidCallback onBackPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: DragToMoveArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBackPressed,
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: AppStrings.backTooltip,
                ),
                const SizedBox(width: 4),
                Text(
                  AppStrings.settingsTitle,
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                const WindowControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
