import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/archive.dart';
import '../api/lanraragi_client.dart';
import '../providers/client_provider.dart';
import '../providers/settings_provider.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({Key? key, required this.archive}) : super(key: key);
  final Archive archive;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  late Future<_ReaderDocument> _documentFuture;
  PageController? _pageController;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  List<GlobalKey> _pageKeys = const [];
  bool _showChrome = true;
  bool _scrollMode = false;
  int _currentPage = 0;
  int _reloadToken = 0;
  int? _lastSyncedPage;
  bool _progressSyncUnsupportedNotified = false;
  bool _pendingVisibilityUpdate = false;

  @override
  void initState() {
    super.initState();
    _documentFuture = _loadDocument();
    _scrollController.addListener(_scheduleVisiblePageUpdate);
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _scrollController.removeListener(_scheduleVisiblePageUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  Future<_ReaderDocument> _loadDocument() async {
    final client = ref.read(lanraragiClientProvider);
    if (client == null) {
      throw LanraragiException('No LANraragi server configured.');
    }

    var archive = widget.archive;
    if ((archive.pageCount ?? 0) <= 0 || archive.progress == null || archive.lastReadTime == null || archive.isNew == null) {
      archive = await client.getArchive(widget.archive.id);
    }

    final pageUrls = await client.getPageUrls(
      widget.archive.id,
      expectedPageCount: archive.pageCount,
    );

    if (pageUrls.isEmpty) {
      throw LanraragiException('No pages available for this archive.');
    }

    final initialPage = _resolveInitialPage(archive.progress, pageUrls.length);
    _pageController?.dispose();
    _pageController = PageController(initialPage: initialPage);
    _pageKeys = List<GlobalKey>.generate(pageUrls.length, (_) => GlobalKey());
    _currentPage = initialPage;
    _lastSyncedPage = null;
    _clearArchiveIsNew(client, archive);

    return _ReaderDocument(archive: archive, pageUrls: pageUrls, initialPage: initialPage);
  }

  int _resolveInitialPage(int? progress, int pageCount) {
    if (progress == null || progress <= 0) {
      return 0;
    }
    final index = progress - 1;
    if (index < 0 || index >= pageCount) {
      return 0;
    }
    return index;
  }

  void _clearArchiveIsNew(LanraragiClient client, Archive archive) {
    if (archive.isNew != true) {
      return;
    }
    client.clearArchiveIsNew(archive.id).catchError((_) {});
  }

  void _toggleChrome() {
    setState(() {
      _showChrome = !_showChrome;
    });
  }

  void _retry() {
    setState(() {
      _reloadToken += 1;
      _documentFuture = _loadDocument();
    });
  }

  void _jumpToPage(int index, _ReaderDocument document) {
    final pageCount = document.pageUrls.length;
    final clamped = index.clamp(0, pageCount - 1);
    if (_scrollMode) {
      final context = _pageKeys[clamped].currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0.05,
        );
      }
      _setCurrentPage(clamped, document.archive.id);
      return;
    }

    _pageController?.animateToPage(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _setCurrentPage(int index, String archiveId) {
    if (_currentPage != index && mounted) {
      setState(() {
        _currentPage = index;
      });
    }
    _syncProgress(archiveId, index);
  }

  void _syncProgress(String archiveId, int pageIndex) {
    if (_lastSyncedPage == pageIndex) {
      return;
    }
    _lastSyncedPage = pageIndex;
    final client = ref.read(lanraragiClientProvider);
    if (client == null) {
      return;
    }
    client.updateArchiveProgress(archiveId, pageIndex + 1).catchError((error) {
      _handleProgressSyncFailure(error);
    });
  }

  void _handleProgressSyncFailure(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('progress tracking is disabled') || message.contains('server-side progress tracking is disabled')) {
      if (_progressSyncUnsupportedNotified || !mounted) {
        return;
      }
      _progressSyncUnsupportedNotified = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server-side progress tracking is disabled on this LANraragi instance.')),
      );
    }
  }

  void _scheduleVisiblePageUpdate() {
    if (!_scrollMode || _pendingVisibilityUpdate) {
      return;
    }
    _pendingVisibilityUpdate = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingVisibilityUpdate = false;
      if (!mounted || !_scrollMode) {
        return;
      }
      _updateVisibleScrollPage();
    });
  }

  void _updateVisibleScrollPage() {
    final viewportContext = _scrollViewportKey.currentContext;
    if (viewportContext == null || _pageKeys.isEmpty) {
      return;
    }
    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      return;
    }
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;

    var bestIndex = _currentPage;
    var bestOverlap = -1.0;
    for (var index = 0; index < _pageKeys.length; index += 1) {
      final context = _pageKeys[index].currentContext;
      if (context == null) {
        continue;
      }
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        continue;
      }
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      final overlap = (bottom < viewportTop || top > viewportBottom)
          ? 0.0
          : (bottom < viewportBottom ? bottom : viewportBottom) - (top > viewportTop ? top : viewportTop);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestIndex = index;
      }
    }
    if (bestOverlap > 0) {
      _setCurrentPage(bestIndex, widget.archive.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = SettingsModel.instance.authHeader();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<_ReaderDocument>(
        future: _documentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final message = snapshot.error.toString().replaceFirst('LanraragiException: ', '');
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.chrome_reader_mode_outlined, color: Colors.white54, size: 42),
                    const SizedBox(height: 16),
                    Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }

          final document = snapshot.data!;
          final pageCount = document.pageUrls.length;
          final title = document.archive.title;
          final pageController = _pageController ?? PageController(initialPage: document.initialPage);

          return Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                child: _scrollMode
                    ? NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollUpdateNotification || notification is ScrollEndNotification) {
                            _scheduleVisiblePageUpdate();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          key: ValueKey('scroll-$_reloadToken'),
                          controller: _scrollController,
                          itemCount: pageCount,
                          itemBuilder: (context, index) {
                            return KeyedSubtree(
                              key: _pageKeys[index],
                              child: _ReaderPage(
                                url: document.pageUrls[index],
                                headers: headers,
                                pageNumber: index + 1,
                                onRetryRequested: _retry,
                              ),
                            );
                          },
                        ),
                      )
                    : PageView.builder(
                        key: ValueKey('pageview-$_reloadToken'),
                        controller: pageController,
                        itemCount: pageCount,
                        onPageChanged: (index) {
                          _setCurrentPage(index, document.archive.id);
                        },
                        itemBuilder: (context, index) {
                          return _ReaderPage(
                            url: document.pageUrls[index],
                            headers: headers,
                            pageNumber: index + 1,
                            onRetryRequested: _retry,
                          );
                        },
                      ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                top: _showChrome ? 0 : -96,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC101217),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.arrow_back),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                                  Text(
                                    '${_currentPage + 1} / $pageCount',
                                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: _scrollMode ? 'Paged mode' : 'Scroll mode',
                              onPressed: () {
                                setState(() {
                                  _scrollMode = !_scrollMode;
                                });
                              },
                              icon: Icon(_scrollMode ? Icons.view_carousel_outlined : Icons.view_stream_outlined),
                            ),
                            IconButton(
                              tooltip: 'Reload pages',
                              onPressed: _retry,
                              icon: const Icon(Icons.refresh),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                bottom: _showChrome ? 0 : -120,
                left: 0,
                right: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC101217),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(trackHeight: 3),
                              child: Slider(
                                min: 0,
                                max: (pageCount - 1).toDouble(),
                                value: _currentPage.clamp(0, pageCount - 1).toDouble(),
                                onChanged: (value) {
                                  _jumpToPage(value.round(), document);
                                },
                              ),
                            ),
                            Row(
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _currentPage > 0 ? () => _jumpToPage(_currentPage - 1, document) : null,
                                  icon: const Icon(Icons.chevron_left),
                                  label: const Text('Previous'),
                                ),
                                const Spacer(),
                                OutlinedButton.icon(
                                  onPressed: _currentPage < pageCount - 1 ? () => _jumpToPage(_currentPage + 1, document) : null,
                                  icon: const Text('Next'),
                                  label: const Icon(Icons.chevron_right),
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
            ],
          );
        },
      ),
    );
  }
}

class _ReaderDocument {
  const _ReaderDocument({required this.archive, required this.pageUrls, required this.initialPage});

  final Archive archive;
  final List<String> pageUrls;
  final int initialPage;
}

class _ReaderPage extends StatelessWidget {
  const _ReaderPage({
    Key? key,
    required this.url,
    required this.headers,
    required this.pageNumber,
    required this.onRetryRequested,
  }) : super(key: key);

  final String url;
  final Map<String, String> headers;
  final int pageNumber;
  final VoidCallback onRetryRequested;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image.network(
            url,
            headers: headers,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }
              final expected = loadingProgress.expectedTotalBytes;
              final loaded = loadingProgress.cumulativeBytesLoaded;
              final value = expected == null || expected == 0 ? null : loaded / expected;
              return Center(
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(value: value),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF15171D),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF2A2E39)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.broken_image_outlined, size: 36, color: Colors.white70),
                        const SizedBox(height: 12),
                        Text('Could not load page $pageNumber', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(
                          'Reload the reader or try another reading mode.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: onRetryRequested,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reload'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
