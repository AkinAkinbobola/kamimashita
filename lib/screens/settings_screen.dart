import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/lanraragi_client.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _apiController = TextEditingController();
  bool _isSaving = false;
  String? _errorText;

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
    final serverUrl = _urlController.text.trim();
    final apiKey = _apiController.text.trim();
    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      final client = LanraragiClient(serverUrl, apiKey);
      await client.getServerInfo();
      await SettingsModel.instance.update(serverUrl: serverUrl, apiKey: apiKey);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on LanraragiException catch (e) {
      setState(() {
        _errorText = e.message;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Server URL', hintText: 'https://lrr.example.local'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiController,
              decoration: const InputDecoration(labelText: 'API Key', hintText: 'Raw or base64-encoded API key'),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _isSaving ? null : _save, child: Text(_isSaving ? 'Testing...' : 'Save')),
              ],
            )
          ],
        ),
      ),
    );
  }
}
