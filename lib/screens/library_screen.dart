import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api.dart';
import '../models/archive.dart';
import '../providers/client_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/cover_card.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  Future<List<Archive>>? _future;
  String _query = '';
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLibrary());
  }

  void _loadLibrary() {
    final client = ref.read(lanraragiClientProvider);
    if (client == null) return;
    setState(() {
      _future = client.listLibrary(start: -1);
    });
  }

  void _search(String q) {
    final client = ref.read(lanraragiClientProvider);
    if (client == null) return;
    setState(() {
      _future = q.trim().isEmpty ? client.listLibrary(start: -1) : client.search(q.trim());
      _query = q;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsModel.instance;
    final hasClient = ref.watch(lanraragiClientProvider) != null;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                onSubmitted: _search,
                decoration: InputDecoration(
                  hintText: 'Search archives',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: hasClient
            ? FutureBuilder<List<Archive>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }
                  final items = snapshot.data ?? [];
                  if (items.isEmpty) return const Center(child: Text('No archives found'));
                  final cross = (MediaQuery.of(context).size.width ~/ 180).clamp(2, 6);
                  return GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cross, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.55),
                    itemCount: items.length,
                    itemBuilder: (context, idx) {
                      final a = items[idx];
                      return CoverCard(
                        archive: a,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderScreen(archive: a))),
                      );
                    },
                  );
                },
              )
            : Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('No server configured'),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())), child: const Text('Configure'))
                ]),
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _loadLibrary(),
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
