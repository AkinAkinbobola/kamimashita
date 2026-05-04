import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/archive.dart';
import '../providers/client_provider.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({Key? key, required this.archive}) : super(key: key);
  final Archive archive;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  Future<List<String>>? _pagesFuture;
  PageController? _pageController;

  @override
  void initState() {
    super.initState();
    final client = ref.read(lanraragiClientProvider);
    if (client != null) {
      _pagesFuture = client.getPageUrls(widget.archive.id);
    } else {
      _pagesFuture = Future.value([]);
    }
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.archive.title)),
      body: FutureBuilder<List<String>>(
        future: _pagesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
          final pages = snapshot.data ?? [];
          if (pages.isEmpty) return const Center(child: Text('No pages available'));
          return PageView.builder(
            controller: _pageController,
            itemCount: pages.length,
            itemBuilder: (context, index) {
              final url = pages[index];
              return InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: url,
                  placeholder: (c, _) => const Center(child: CircularProgressIndicator()),
                  errorWidget: (c, _, __) => const Center(child: Icon(Icons.broken_image)),
                  fit: BoxFit.contain,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
