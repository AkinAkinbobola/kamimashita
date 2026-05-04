import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _apiController = TextEditingController();

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
    await SettingsModel.instance.update(serverUrl: _urlController.text.trim(), apiKey: _apiController.text.trim());
    if (mounted) Navigator.of(context).pop();
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
              decoration: const InputDecoration(labelText: 'API Key (base64)', hintText: 'Base64-encoded API key'),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _save, child: const Text('Save')),
              ],
            )
          ],
        ),
      ),
    );
  }
}
