import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/lanraragi_client.dart';
import '../models/archive.dart';
import '../providers/client_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/theme.dart';

enum ReaderFitMode { contain, fitWidth, fitHeight, originalSize }

class _StaleReaderLoadException implements Exception {
  const _StaleReaderLoadException();
}

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.archive, this.initialPage});

  final Archive archive;
  final int? initialPage;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WindowListener {
  late Future<_ReaderDocument> _documentFuture;
  final FocusNode _readerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  PageController? _pageController;
  Timer? _chromeHideTimer;
  Timer? _progressSyncTimer;

  bool _showChrome = true;
  bool _autoHideChrome = true;
  bool _showSettingsPopover = false;
  bool _continuousScroll = false;
  bool _rightToLeft = false;
  bool _isFullscreen = false;
  int _currentPage = 0;
  int _reloadToken = 0;
  int? _lastSyncedPage;
  int? _pendingProgressPage;
  bool _progressSyncUnsupportedNotified = false;
  bool _pendingVisibilityUpdate = false;
  bool _didApplyStoredPreferences = false;
  DateTime? _lastPagedWheelPageTurnAt;
  double _pagedZoomScale = 1.0;
  ReaderFitMode _fitMode = ReaderFitMode.contain;
  List<String> _pageUrls = const [];
  List<GlobalKey> _pageKeys = const [];
  List<GlobalKey<_ReaderPageState>> _pagedPageKeys = const [];
  Map<String, ImageProvider<Object>> _pageImageProviders = {};

  @override
  void initState() {
    super.initState();
    if (_supportsWindowFullscreen) {
      windowManager.addListener(this);
    }
    SettingsModel.instance.addListener(_handleSettingsChanged);
    _applyStoredPreferencesIfReady();
    _documentFuture = _loadDocument();
    _scrollController.addListener(_scheduleVisiblePageUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _readerFocusNode.requestFocus();
        _scheduleChromeHide();
        _loadFullscreenState();
      }
    });
  }

  @override
  void dispose() {
    _chromeHideTimer?.cancel();
    _progressSyncTimer?.cancel();
    if (_supportsWindowFullscreen) {
      windowManager.removeListener(this);
    }
    SettingsModel.instance.removeListener(_handleSettingsChanged);
    _pageController?.dispose();
    _scrollController.removeListener(_scheduleVisiblePageUpdate);
    _scrollController.dispose();
    _readerFocusNode.dispose();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = true;
    });
    unawaited(SettingsModel.instance.updateReaderPreferences(fullscreen: true));
    _revealChrome();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = false;
    });
    unawaited(
      SettingsModel.instance.updateReaderPreferences(fullscreen: false),
    );
    _revealChrome();
  }

  void _handleSettingsChanged() {
    _applyStoredPreferencesIfReady();
  }

  void _applyStoredPreferencesIfReady() {
    final settings = SettingsModel.instance;
    if (_didApplyStoredPreferences || !settings.isLoaded) {
      return;
    }

    _didApplyStoredPreferences = true;
    if (mounted) {
      setState(() {
        _fitMode = _readerFitModeFromStorage(settings.readerFitMode);
        _continuousScroll = settings.readerContinuousScroll;
        _rightToLeft = settings.readerRightToLeft;
        _autoHideChrome = settings.readerAutoHideChrome;
        _showChrome = true;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncModeViewport(_currentPage, animate: false);
      if (_autoHideChrome) {
        _scheduleChromeHide();
      } else {
        _chromeHideTimer?.cancel();
      }
    });

    if (_supportsWindowFullscreen) {
      unawaited(_applyStoredFullscreenPreference(settings.readerFullscreen));
    }
  }

  ReaderFitMode _readerFitModeFromStorage(String value) {
    return switch (value) {
      'fitWidth' => ReaderFitMode.fitWidth,
      'fitHeight' => ReaderFitMode.fitHeight,
      'originalSize' => ReaderFitMode.originalSize,
      _ => ReaderFitMode.contain,
    };
  }

  Future<void> _applyStoredFullscreenPreference(bool preferred) async {
    final current = await windowManager.isFullScreen();
    if (current != preferred) {
      await windowManager.setFullScreen(preferred);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = preferred;
    });
  }

  Future<void> _loadFullscreenState() async {
    if (!_supportsWindowFullscreen) {
      return;
    }
    final isFullscreen = await windowManager.isFullScreen();
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = isFullscreen;
    });
  }

  Future<_ReaderDocument> _loadDocument() async {
    final requestToken = _reloadToken;
    final client = ref.read(lanraragiClientProvider);
    if (client == null) {
      throw LanraragiException('No LANraragi server configured.');
    }

    var archive = widget.archive;
    if ((archive.pageCount ?? 0) <= 0 ||
        archive.progress == null ||
        archive.lastReadTime == null ||
        archive.isNew == null) {
      archive = await client.getArchive(widget.archive.id);
    }

    final pageUrls = await client.getPageUrls(
      widget.archive.id,
      expectedPageCount: archive.pageCount,
    );

    if (!_isActiveDocumentRequest(requestToken)) {
      throw const _StaleReaderLoadException();
    }

    if (pageUrls.isEmpty) {
      throw LanraragiException('No pages available for this archive.');
    }

    final initialPage = _resolveInitialPage(
      widget.initialPage ?? archive.progress,
      pageUrls.length,
    );
    final headers = Map<String, String>.unmodifiable(
      SettingsModel.instance.authHeader(),
    );
    final imageProviders = <String, ImageProvider<Object>>{
      for (var index = 0; index < pageUrls.length; index += 1)
        _pageProviderKey(widget.archive.id, index + 1): NetworkImage(
          pageUrls[index],
          headers: headers,
        ),
    };

    if (!_isActiveDocumentRequest(requestToken)) {
      throw const _StaleReaderLoadException();
    }

    _pageController?.dispose();
    _pageController = PageController(initialPage: initialPage);
    _currentPage = initialPage;
    _pageKeys = List<GlobalKey>.generate(pageUrls.length, (_) => GlobalKey());
    _pagedPageKeys = List<GlobalKey<_ReaderPageState>>.generate(
      pageUrls.length,
      (_) => GlobalKey<_ReaderPageState>(),
    );
    _lastSyncedPage = null;
    _pendingProgressPage = null;
    _pageUrls = pageUrls;
    _pageImageProviders = imageProviders;
    _clearArchiveIsNew(client, archive);
    _recordOnDeckEntry(archive.title, initialPage + 1, pageUrls.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isActiveDocumentRequest(requestToken)) {
        _prefetchAdjacentPages(initialPage);
        _syncModeViewport(initialPage, animate: false);
      }
    });

    return _ReaderDocument(
      archive: archive,
      pageUrls: pageUrls,
      initialPage: initialPage,
    );
  }

  bool _isActiveDocumentRequest(int requestToken) {
    return mounted && requestToken == _reloadToken;
  }

  String _pageProviderKey(String archiveId, int pageNumber) {
    return '$archiveId:$pageNumber';
  }

  ImageProvider<Object> _pageImageProvider(
    String archiveId,
    int pageNumber,
    String fallbackUrl,
    Map<String, String> headers,
  ) {
    return _pageImageProviders.putIfAbsent(
      _pageProviderKey(archiveId, pageNumber),
      () => NetworkImage(
        fallbackUrl,
        headers: Map<String, String>.unmodifiable(headers),
      ),
    );
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

  void _recordOnDeckEntry(String title, int currentPage, int totalPages) {
    unawaited(
      SettingsModel.instance.upsertOnDeckEntry(
        archiveId: widget.archive.id,
        title: title,
        currentPage: currentPage,
        totalPages: totalPages,
      ),
    );
  }

  void _clearArchiveIsNew(LanraragiClient client, Archive archive) {
    if (archive.isNew != true) {
      return;
    }
    client.clearArchiveIsNew(archive.id).catchError((_) {});
  }

  bool get _supportsWindowFullscreen {
    if (kIsWeb) {
      return false;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  void _revealChrome({bool resetTimer = true}) {
    if (!mounted) {
      return;
    }
    if (!_showChrome) {
      setState(() {
        _showChrome = true;
      });
    }
    if (resetTimer) {
      _scheduleChromeHide();
    }
  }

  void _scheduleChromeHide() {
    _chromeHideTimer?.cancel();
    if (!_autoHideChrome || _showSettingsPopover) {
      return;
    }
    _chromeHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_autoHideChrome || _showSettingsPopover) {
        return;
      }
      setState(() {
        _showChrome = false;
      });
    });
  }

  void _toggleControls() {
    if (_showChrome) {
      _chromeHideTimer?.cancel();
      setState(() {
        _showChrome = false;
        _showSettingsPopover = false;
      });
      return;
    }
    _revealChrome();
  }

  void _closeSettingsPopover() {
    if (!_showSettingsPopover) {
      return;
    }
    setState(() {
      _showSettingsPopover = false;
      _showChrome = true;
    });
    _scheduleChromeHide();
  }

  void _toggleSettingsPopover() {
    setState(() {
      _showSettingsPopover = !_showSettingsPopover;
      _showChrome = true;
    });
    _scheduleChromeHide();
  }

  void _retry() {
    _revealChrome();
    setState(() {
      _reloadToken += 1;
      _showSettingsPopover = false;
      _documentFuture = _loadDocument();
    });
  }

  void _jumpToPage(int index, _ReaderDocument document) {
    final clamped = index.clamp(0, document.pageUrls.length - 1);
    if (clamped == _currentPage) {
      return;
    }
    if (_continuousScroll) {
      _scrollToPage(clamped, animate: true);
    } else {
      _rememberCurrentPagedZoom();
      _pageController?.jumpToPage(clamped);
    }
  }

  void _rememberCurrentPagedZoom() {
    if (_continuousScroll ||
        _currentPage < 0 ||
        _currentPage >= _pagedPageKeys.length) {
      return;
    }

    final currentState = _pagedPageKeys[_currentPage].currentState;
    if (currentState == null) {
      return;
    }

    _pagedZoomScale = currentState.currentScale;
  }

  bool _consumePagedWheelNavigationCooldown() {
    final now = DateTime.now();
    if (_lastPagedWheelPageTurnAt != null &&
        now.difference(_lastPagedWheelPageTurnAt!) <
            const Duration(milliseconds: 200)) {
      return false;
    }
    _lastPagedWheelPageTurnAt = now;
    return true;
  }

  void _goNextPage(_ReaderDocument document, {bool fromWheel = false}) {
    if (!_canGoReadingForward(document.pageUrls.length)) {
      return;
    }
    if (fromWheel && !_consumePagedWheelNavigationCooldown()) {
      return;
    }
    _goReadingForward(document);
  }

  void _goPreviousPage(_ReaderDocument document, {bool fromWheel = false}) {
    if (!_canGoReadingBackward(document.pageUrls.length)) {
      return;
    }
    if (fromWheel && !_consumePagedWheelNavigationCooldown()) {
      return;
    }
    _goReadingBackward(document);
  }

  void _setContinuousScroll(bool value) {
    if (_continuousScroll == value) {
      return;
    }
    final targetPage = _currentPage;
    setState(() {
      _continuousScroll = value;
      _pagedZoomScale = 1.0;
    });
    unawaited(
      SettingsModel.instance.updateReaderPreferences(continuousScroll: value),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncModeViewport(targetPage, animate: false);
      _revealChrome();
    });
  }

  void _syncModeViewport(int pageIndex, {required bool animate}) {
    if (_continuousScroll) {
      _scrollToPage(pageIndex, animate: animate);
      return;
    }

    if (_pageController == null) {
      return;
    }

    if (animate) {
      _pageController!.animateToPage(
        pageIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    _pageController!.jumpToPage(pageIndex);
  }

  void _scrollToPage(int pageIndex, {required bool animate}) {
    if (!_scrollController.hasClients ||
        pageIndex < 0 ||
        pageIndex >= _pageKeys.length) {
      return;
    }

    final targetContext = _pageKeys[pageIndex].currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        duration: animate ? const Duration(milliseconds: 220) : Duration.zero,
        curve: Curves.easeOutCubic,
        alignment: 0.04,
      );
      return;
    }

    final position = _scrollController.position;
    final viewportHeight = position.viewportDimension <= 0
        ? MediaQuery.sizeOf(context).height
        : position.viewportDimension;
    final estimatedOffset = (viewportHeight * pageIndex).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if (animate) {
      _scrollController.animateTo(
        estimatedOffset,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    _scrollController.jumpTo(estimatedOffset);
  }

  void _goReadingBackward(_ReaderDocument document) {
    final target = _rightToLeft ? _currentPage + 1 : _currentPage - 1;
    _jumpToPage(target, document);
  }

  void _goReadingForward(_ReaderDocument document) {
    final target = _rightToLeft ? _currentPage - 1 : _currentPage + 1;
    _jumpToPage(target, document);
  }

  bool _canGoReadingBackward(int pageCount) {
    return _rightToLeft ? _currentPage < pageCount - 1 : _currentPage > 0;
  }

  bool _canGoReadingForward(int pageCount) {
    return _rightToLeft ? _currentPage > 0 : _currentPage < pageCount - 1;
  }

  void _setCurrentPage(int index, String archiveId) {
    if (_currentPage != index && mounted) {
      setState(() {
        _currentPage = index;
        _pagedPageKeys = List<GlobalKey<_ReaderPageState>>.generate(
          _pageUrls.length,
          (_) => GlobalKey<_ReaderPageState>(),
        );
      });
    }
    _recordOnDeckEntry(widget.archive.title, index + 1, _pageUrls.length);
    _queueProgressSync(archiveId, index);
    _prefetchAdjacentPages(index);
  }

  void _queueProgressSync(String archiveId, int pageIndex) {
    if (_lastSyncedPage == pageIndex || _pendingProgressPage == pageIndex) {
      return;
    }

    _pendingProgressPage = pageIndex;
    _progressSyncTimer?.cancel();
    _progressSyncTimer = Timer(const Duration(milliseconds: 300), () {
      final queuedPage = _pendingProgressPage;
      if (queuedPage == null) {
        return;
      }

      _pendingProgressPage = null;
      _lastSyncedPage = queuedPage;
      final client = ref.read(lanraragiClientProvider);
      if (client == null) {
        return;
      }

      client
          .updateArchiveProgress(archiveId, queuedPage + 1)
          .then((_) {
            return SettingsModel.instance.setUseLocalOnDeckFallback(false);
          })
          .catchError((error) {
            _handleProgressSyncFailure(error);
          });
    });
  }

  void _handleProgressSyncFailure(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('progress tracking is disabled') ||
        message.contains('server-side progress tracking is disabled')) {
      unawaited(SettingsModel.instance.setUseLocalOnDeckFallback(true));
      if (_progressSyncUnsupportedNotified || !mounted) {
        return;
      }
      _progressSyncUnsupportedNotified = true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Server-side progress tracking is disabled on this LANraragi instance.',
          ),
        ),
      );
    }
  }

  void _prefetchAdjacentPages(int pageIndex) {
    if (!mounted || _pageUrls.isEmpty) {
      return;
    }

    final headers = SettingsModel.instance.authHeader();
    final start = (pageIndex - 2).clamp(0, _pageUrls.length - 1);
    final end = (pageIndex + 2).clamp(0, _pageUrls.length - 1);
    for (var index = start; index <= end; index += 1) {
      if (index == pageIndex) {
        continue;
      }
      precacheImage(
        _pageImageProvider(
          widget.archive.id,
          index + 1,
          _pageUrls[index],
          headers,
        ),
        context,
      );
    }
  }

  void _scheduleVisiblePageUpdate() {
    if (!_continuousScroll || _pendingVisibilityUpdate) {
      return;
    }
    _pendingVisibilityUpdate = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingVisibilityUpdate = false;
      if (!mounted || !_continuousScroll) {
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
    final viewportCenter = viewportTop + (viewportBox.size.height / 2);
    var bestIndex = _currentPage;
    var bestDistance = double.infinity;

    for (var index = 0; index < _pageKeys.length; index += 1) {
      final pageContext = _pageKeys[index].currentContext;
      if (pageContext == null) {
        continue;
      }
      final box = pageContext.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        continue;
      }

      final pageTop = box.localToGlobal(Offset.zero).dy;
      final pageCenter = pageTop + (box.size.height / 2);
      final distance = (pageCenter - viewportCenter).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
      }
    }

    if (bestDistance.isFinite) {
      _setCurrentPage(bestIndex, widget.archive.id);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (!_supportsWindowFullscreen) {
      return;
    }
    final nextValue = !await windowManager.isFullScreen();
    await windowManager.setFullScreen(nextValue);
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = nextValue;
    });
    unawaited(
      SettingsModel.instance.updateReaderPreferences(fullscreen: nextValue),
    );
    _revealChrome();
  }

  void _exitReader() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event, _ReaderDocument document) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.pageUp:
        _goPreviousPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.pageDown:
        _goNextPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyA:
        _goPreviousPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyD:
        _goNextPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _goPreviousPage(document);
        } else {
          _goNextPage(document);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        _toggleControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_showSettingsPopover) {
          setState(() {
            _showSettingsPopover = false;
            _showChrome = true;
          });
          _scheduleChromeHide();
          return KeyEventResult.handled;
        }
        if (!_showChrome) {
          _toggleControls();
          return KeyEventResult.handled;
        }
        if (_isFullscreen) {
          _toggleFullscreen();
          return KeyEventResult.handled;
        }
        _exitReader();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = SettingsModel.instance.authHeader();
    final theme = Theme.of(context);

    return SelectionContainer.disabled(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: FutureBuilder<_ReaderDocument>(
          future: _documentFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError &&
                snapshot.error is _StaleReaderLoadException) {
              return const SizedBox.shrink();
            }

            if (snapshot.hasError) {
              final message = snapshot.error.toString().replaceFirst(
                'LanraragiException: ',
                '',
              );
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.chrome_reader_mode_outlined,
                        color: Colors.white54,
                        size: 42,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _retry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }

            final document = snapshot.data!;
            final pageCount = document.pageUrls.length;
            final chromeVisible = _showChrome || _showSettingsPopover;
            final pageController =
                _pageController ??
                PageController(initialPage: document.initialPage);

            return Focus(
              focusNode: _readerFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) => _handleKeyEvent(event, document),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black,
                      child: _continuousScroll
                          ? NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                if (notification is ScrollUpdateNotification ||
                                    notification is ScrollEndNotification) {
                                  _scheduleVisiblePageUpdate();
                                }
                                return false;
                              },
                              child: Container(
                                key: _scrollViewportKey,
                                child: _Scrollbarless(
                                  child: ListView.builder(
                                    key: ValueKey('scroll-$_reloadToken'),
                                    controller: _scrollController,
                                    cacheExtent:
                                        MediaQuery.sizeOf(context).height * 1.5,
                                    itemCount: pageCount,
                                    itemBuilder: (context, index) {
                                      return KeyedSubtree(
                                        key: _pageKeys[index],
                                        child: _ReaderPage(
                                          imageProvider: _pageImageProvider(
                                            document.archive.id,
                                            index + 1,
                                            document.pageUrls[index],
                                            headers,
                                          ),
                                          pageNumber: index + 1,
                                          fitMode: _fitMode,
                                          zoomEnabled: false,
                                          onInteraction: _revealChrome,
                                          onRetryRequested: _retry,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            )
                          : PageView.builder(
                              key: ValueKey(
                                'pageview-$_reloadToken-$_rightToLeft',
                              ),
                              controller: pageController,
                              reverse: _rightToLeft,
                              itemCount: pageCount,
                              onPageChanged: (index) {
                                _rememberCurrentPagedZoom();
                                _setCurrentPage(index, document.archive.id);
                              },
                              itemBuilder: (context, index) {
                                return _ReaderPage(
                                  key: _pagedPageKeys[index],
                                  imageProvider: _pageImageProvider(
                                    document.archive.id,
                                    index + 1,
                                    document.pageUrls[index],
                                    headers,
                                  ),
                                  pageNumber: index + 1,
                                  fitMode: _fitMode,
                                  zoomEnabled: true,
                                  zoomScale: _pagedZoomScale,
                                  pagedNavigationEnabled: true,
                                  onNextPageRequested: () =>
                                      _goNextPage(document, fromWheel: false),
                                  onPreviousPageRequested: () =>
                                      _goPreviousPage(
                                        document,
                                        fromWheel: false,
                                      ),
                                  onNextPageFromWheelRequested: () =>
                                      _goNextPage(document, fromWheel: true),
                                  onPreviousPageFromWheelRequested: () =>
                                      _goPreviousPage(
                                        document,
                                        fromWheel: true,
                                      ),
                                  onToggleControlsRequested: _toggleControls,
                                  onInteraction: null,
                                  onRetryRequested: _retry,
                                );
                              },
                            ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !chromeVisible,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: chromeVisible ? 1 : 0,
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xB3101217),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: const Color(0xFF252B36),
                                  width: 0.5,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    _ReaderBarButton(
                                      tooltip: 'Exit reader',
                                      icon: Icons.arrow_back_rounded,
                                      onPressed: _exitReader,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            document.archive.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(color: Colors.white),
                                          ),
                                          Text(
                                            '${_currentPage + 1} / $pageCount',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.white70,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _ReaderBarButton(
                                      tooltip: 'Reader settings',
                                      icon: Icons.tune_rounded,
                                      onPressed: _toggleSettingsPopover,
                                      active: _showSettingsPopover,
                                    ),
                                    if (_supportsWindowFullscreen) ...[
                                      const SizedBox(width: 4),
                                      _ReaderBarButton(
                                        tooltip: _isFullscreen
                                            ? 'Exit fullscreen'
                                            : 'Fullscreen',
                                        icon: _isFullscreen
                                            ? Icons.fullscreen_exit_rounded
                                            : Icons.fullscreen_rounded,
                                        onPressed: _toggleFullscreen,
                                        active: _isFullscreen,
                                      ),
                                    ],
                                    const SizedBox(width: 4),
                                    _ReaderBarButton(
                                      tooltip: 'Reload pages',
                                      icon: Icons.refresh_rounded,
                                      onPressed: _retry,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !chromeVisible,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: chromeVisible ? 1 : 0,
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xB3101217),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: const Color(0xFF252B36),
                                  width: 0.5,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    _ReaderBarButton(
                                      tooltip: 'Previous page',
                                      icon: Icons.chevron_left_rounded,
                                      onPressed:
                                          _canGoReadingBackward(pageCount)
                                          ? () => _goReadingBackward(document)
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 3,
                                          overlayShape:
                                              SliderComponentShape.noOverlay,
                                          activeTrackColor: AppTheme.crimson,
                                          inactiveTrackColor: Colors.white24,
                                          thumbColor: Colors.white,
                                        ),
                                        child: Slider(
                                          min: 0,
                                          max: (pageCount - 1).toDouble(),
                                          value: _currentPage
                                              .clamp(0, pageCount - 1)
                                              .toDouble(),
                                          onChanged: (value) {
                                            _jumpToPage(
                                              value.round(),
                                              document,
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${_currentPage + 1} / $pageCount',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(color: Colors.white70),
                                    ),
                                    const SizedBox(width: 8),
                                    _ReaderBarButton(
                                      tooltip: 'Next page',
                                      icon: Icons.chevron_right_rounded,
                                      onPressed: _canGoReadingForward(pageCount)
                                          ? () => _goReadingForward(document)
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_showSettingsPopover)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeSettingsPopover,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  if (_showSettingsPopover)
                    Positioned(
                      top: 76,
                      right: 16,
                      child: SafeArea(
                        bottom: false,
                        child: _ReaderSettingsPopover(
                          fitMode: _fitMode,
                          continuousScroll: _continuousScroll,
                          rightToLeft: _rightToLeft,
                          autoHideChrome: _autoHideChrome,
                          onFitModeChanged: (mode) {
                            setState(() {
                              _fitMode = mode;
                              _pagedZoomScale = 1.0;
                            });
                            unawaited(
                              SettingsModel.instance.updateReaderPreferences(
                                fitMode: mode.name,
                              ),
                            );
                            _revealChrome();
                          },
                          onContinuousScrollChanged: _setContinuousScroll,
                          onRightToLeftChanged: (value) {
                            setState(() {
                              _rightToLeft = value;
                            });
                            unawaited(
                              SettingsModel.instance.updateReaderPreferences(
                                rightToLeft: value,
                              ),
                            );
                            _revealChrome();
                          },
                          onAutoHideChanged: (value) {
                            setState(() {
                              _autoHideChrome = value;
                              _showChrome = true;
                            });
                            unawaited(
                              SettingsModel.instance.updateReaderPreferences(
                                autoHideChrome: value,
                              ),
                            );
                            if (value) {
                              _scheduleChromeHide();
                            } else {
                              _chromeHideTimer?.cancel();
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReaderDocument {
  const _ReaderDocument({
    required this.archive,
    required this.pageUrls,
    required this.initialPage,
  });

  final Archive archive;
  final List<String> pageUrls;
  final int initialPage;
}

class _ReaderBarButton extends StatefulWidget {
  const _ReaderBarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;

  @override
  State<_ReaderBarButton> createState() => _ReaderBarButtonState();
}

class _ReaderBarButtonState extends State<_ReaderBarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final foregroundColor = !enabled
        ? Colors.white24
        : widget.active || _hovered
        ? Colors.white
        : Colors.white70;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(widget.icon, size: 18, color: foregroundColor),
          ),
        ),
      ),
    );
  }
}

class _ReaderSettingsPopover extends StatelessWidget {
  static const _accent = Color(0xFF49D7E8);

  const _ReaderSettingsPopover({
    required this.fitMode,
    required this.continuousScroll,
    required this.rightToLeft,
    required this.autoHideChrome,
    required this.onFitModeChanged,
    required this.onContinuousScrollChanged,
    required this.onRightToLeftChanged,
    required this.onAutoHideChanged,
  });

  final ReaderFitMode fitMode;
  final bool continuousScroll;
  final bool rightToLeft;
  final bool autoHideChrome;
  final ValueChanged<ReaderFitMode> onFitModeChanged;
  final ValueChanged<bool> onContinuousScrollChanged;
  final ValueChanged<bool> onRightToLeftChanged;
  final ValueChanged<bool> onAutoHideChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF252B36), width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Reader settings',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Fit',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children:
                    [
                          ('Contain', ReaderFitMode.contain),
                          ('Width', ReaderFitMode.fitWidth),
                          ('Height', ReaderFitMode.fitHeight),
                          ('Original', ReaderFitMode.originalSize),
                        ]
                        .map(
                          (option) => _ReaderTextToggle(
                            label: option.$1,
                            selected: fitMode == option.$2,
                            onTap: () => onFitModeChanged(option.$2),
                            accentColor: _accent,
                          ),
                        )
                        .toList(growable: false),
              ),
              const SizedBox(height: 12),
              Text(
                'Reading mode',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _ReaderTextToggle(
                    label: 'Paged',
                    selected: !continuousScroll,
                    onTap: () => onContinuousScrollChanged(false),
                    accentColor: _accent,
                  ),
                  _ReaderTextToggle(
                    label: 'Scroll',
                    selected: continuousScroll,
                    onTap: () => onContinuousScrollChanged(true),
                    accentColor: _accent,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Direction',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _ReaderTextToggle(
                    label: 'Left to right',
                    selected: !rightToLeft,
                    onTap: () => onRightToLeftChanged(false),
                    accentColor: _accent,
                  ),
                  _ReaderTextToggle(
                    label: 'Right to left',
                    selected: rightToLeft,
                    onTap: () => onRightToLeftChanged(true),
                    accentColor: _accent,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Auto-hide controls',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: autoHideChrome,
                    onChanged: onAutoHideChanged,
                    activeThumbColor: _accent,
                    activeTrackColor: _accent.withValues(alpha: 0.36),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderTextToggle extends StatefulWidget {
  const _ReaderTextToggle({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.accentColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color accentColor;

  @override
  State<_ReaderTextToggle> createState() => _ReaderTextToggleState();
}

class _ReaderTextToggleState extends State<_ReaderTextToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.selected
        ? const Color(0xFF131B1D)
        : _hovered
        ? const Color(0xFF202020)
        : Colors.transparent;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: background,
            border: Border(
              bottom: BorderSide(
                color: widget.selected
                    ? widget.accentColor
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Text(
            widget.label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: widget.selected ? widget.accentColor : AppTheme.textMuted,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderPage extends StatefulWidget {
  const _ReaderPage({
    super.key,
    required this.imageProvider,
    required this.pageNumber,
    required this.fitMode,
    required this.zoomEnabled,
    this.zoomScale = 1.0,
    this.pagedNavigationEnabled = false,
    this.onNextPageRequested,
    this.onPreviousPageRequested,
    this.onNextPageFromWheelRequested,
    this.onPreviousPageFromWheelRequested,
    this.onToggleControlsRequested,
    required this.onInteraction,
    required this.onRetryRequested,
  });

  final ImageProvider<Object> imageProvider;
  final int pageNumber;
  final ReaderFitMode fitMode;
  final bool zoomEnabled;
  final double zoomScale;
  final bool pagedNavigationEnabled;
  final VoidCallback? onNextPageRequested;
  final VoidCallback? onPreviousPageRequested;
  final VoidCallback? onNextPageFromWheelRequested;
  final VoidCallback? onPreviousPageFromWheelRequested;
  final VoidCallback? onToggleControlsRequested;
  final VoidCallback? onInteraction;
  final VoidCallback onRetryRequested;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _Scrollbarless extends StatelessWidget {
  const _Scrollbarless({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: child,
    );
  }
}

class _ReaderPageState extends State<_ReaderPage> {
  final TransformationController _transformationController =
      TransformationController();
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  ImageInfo? _imageInfo;
  Object? _imageError;
  double _lastReportedScale = 1.0;

  @override
  void initState() {
    super.initState();
    _transformationController.value = _matrixForScale(widget.zoomScale);
    _transformationController.addListener(_handleTransformationChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fitMode != widget.fitMode ||
        oldWidget.zoomEnabled != widget.zoomEnabled ||
        oldWidget.zoomScale != widget.zoomScale) {
      _transformationController.value = _matrixForScale(widget.zoomScale);
    }
    if (oldWidget.imageProvider != widget.imageProvider) {
      _resolveImage(force: true);
    }
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream!.removeListener(_imageStreamListener!);
    }
    _transformationController.removeListener(_handleTransformationChanged);
    _transformationController.dispose();
    super.dispose();
  }

  double get currentScale => _currentScale.clamp(1.0, 4.0);

  void _handleTransformationChanged() {
    final scale = currentScale;
    if ((scale - _lastReportedScale).abs() <= 0.001) {
      return;
    }
    _lastReportedScale = scale;
    if (mounted) {
      setState(() {});
    }
  }

  void _resolveImage({bool force = false}) {
    final stream = widget.imageProvider.resolve(
      createLocalImageConfiguration(context),
    );
    if (!force && _imageStream?.key == stream.key) {
      return;
    }

    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream!.removeListener(_imageStreamListener!);
    }

    _imageInfo = null;
    _imageError = null;

    _imageStream = stream;
    _imageStreamListener = ImageStreamListener(
      (imageInfo, _) {
        if (!mounted) {
          return;
        }
        setState(() {
          _imageInfo = imageInfo;
          _imageError = null;
        });
      },
      onError: (error, _) {
        if (!mounted) {
          return;
        }
        setState(() {
          _imageInfo = null;
          _imageError = error;
        });
      },
    );
    _imageStream!.addListener(_imageStreamListener!);
  }

  Matrix4 _matrixForScale(double scale) {
    final clampedScale = scale.clamp(1.0, 4.0);
    return Matrix4.identity()..scale(clampedScale);
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  double get _currentScale =>
      _transformationController.value.getMaxScaleOnAxis();

  bool get _canPanZoomedImage => _currentScale > 1.01;

  bool get _useConstrainedViewer => widget.fitMode == ReaderFitMode.contain;

  void _applyScaleAroundPoint(double scale, Offset focalPoint) {
    final clampedScale = scale.clamp(1.0, 4.0);
    if (clampedScale <= 1.0) {
      _resetZoom();
      return;
    }

    final scenePoint = _transformationController.toScene(focalPoint);
    _transformationController.value = Matrix4.identity()
      ..translate(
        focalPoint.dx - scenePoint.dx * clampedScale,
        focalPoint.dy - scenePoint.dy * clampedScale,
      )
      ..scale(clampedScale);
  }

  void _resetZoomToDefault() {
    if (!widget.zoomEnabled) {
      return;
    }
    _resetZoom();
    widget.onInteraction?.call();
  }

  void _handlePagedViewportTap(TapUpDetails details, Size viewportSize) {
    if (_canPanZoomedImage) {
      return;
    }
    final ratio = viewportSize.width <= 0
        ? 0.5
        : details.localPosition.dx / viewportSize.width;
    if (ratio < 0.33) {
      widget.onPreviousPageRequested?.call();
      return;
    }
    if (ratio <= 0.67) {
      widget.onToggleControlsRequested?.call();
      return;
    }
    widget.onNextPageRequested?.call();
  }

  void _handlePagedPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }
    final deltaY = event.scrollDelta.dy;
    if (deltaY == 0) {
      return;
    }

    if (HardwareKeyboard.instance.isControlPressed && widget.zoomEnabled) {
      final zoomFactor = math.exp(-deltaY / 240);
      _applyScaleAroundPoint(_currentScale * zoomFactor, event.localPosition);
      widget.onInteraction?.call();
      return;
    }

    if (!widget.pagedNavigationEnabled) {
      return;
    }

    if (deltaY > 0) {
      widget.onNextPageFromWheelRequested?.call();
      return;
    }

    widget.onPreviousPageFromWheelRequested?.call();
  }

  Size _effectiveViewportSize(BoxConstraints constraints) {
    final mediaSize = MediaQuery.sizeOf(context);
    final width = constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : mediaSize.width;
    final height = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : math.max(1.0, mediaSize.height - 36);
    return Size(width, height);
  }

  ({Size size, Alignment alignment}) _resolveImageLayout(
    BoxConstraints constraints,
  ) {
    final imageInfo = _imageInfo!;
    final viewport = _effectiveViewportSize(constraints);
    final intrinsic = Size(
      imageInfo.image.width / imageInfo.scale,
      imageInfo.image.height / imageInfo.scale,
    );
    final widthScale = viewport.width / intrinsic.width;
    final heightScale = viewport.height / intrinsic.height;

    final fittedScale = switch (widget.fitMode) {
      ReaderFitMode.contain => math.min(widthScale, heightScale),
      ReaderFitMode.fitWidth => widthScale,
      ReaderFitMode.fitHeight => heightScale,
      ReaderFitMode.originalSize => math.min(
        1.0,
        math.min(widthScale, heightScale),
      ),
    };

    final safeScale = fittedScale.isFinite && fittedScale > 0
        ? fittedScale
        : 1.0;
    final size = Size(
      intrinsic.width * safeScale,
      intrinsic.height * safeScale,
    );
    final alignment = size.height > viewport.height + 1
        ? Alignment.topCenter
        : Alignment.center;
    return (size: size, alignment: alignment);
  }

  Widget _buildLoadingState(BoxConstraints constraints) {
    final viewport = _effectiveViewportSize(constraints);

    return SizedBox(
      width: viewport.width,
      height: viewport.height,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF11141B),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF252B36)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Page ${widget.pageNumber}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context) {
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
              const Icon(
                Icons.broken_image_outlined,
                size: 36,
                color: Colors.white70,
              ),
              const SizedBox(height: 12),
              Text(
                'Could not load page ${widget.pageNumber}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Reload the reader or try another fit mode.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: widget.onRetryRequested,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(BoxConstraints constraints) {
    if (_imageError != null) {
      return _buildErrorState(context);
    }
    if (_imageInfo == null) {
      return _buildLoadingState(constraints);
    }

    final layout = _resolveImageLayout(constraints);
    final viewport = _effectiveViewportSize(constraints);
    final image = RawImage(
      image: _imageInfo!.image,
      scale: _imageInfo!.scale,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );

    if (!_useConstrainedViewer) {
      return SizedBox(
        width: layout.size.width,
        height: layout.size.height,
        child: image,
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: viewport.width,
        minHeight: viewport.height,
      ),
      child: Align(
        alignment: layout.alignment,
        child: SizedBox(
          width: layout.size.width,
          height: layout.size.height,
          child: image,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = _effectiveViewportSize(constraints);
        final image = _buildImage(constraints);
        final zoomableImage = widget.zoomEnabled
            ? InteractiveViewer(
                transformationController: _transformationController,
                minScale: 1,
                maxScale: 4,
                panEnabled: _canPanZoomedImage,
                scaleEnabled: true,
                constrained: _useConstrainedViewer,
                boundaryMargin: const EdgeInsets.all(80),
                clipBehavior: Clip.none,
                child: image,
              )
            : image;

        if (widget.pagedNavigationEnabled) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            child: Listener(
              onPointerSignal: _handlePagedPointerSignal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.zoomEnabled ? _resetZoomToDefault : null,
                onTapUp: (details) =>
                    _handlePagedViewportTap(details, viewportSize),
                child: zoomableImage,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
          child: GestureDetector(
            onDoubleTap: widget.zoomEnabled ? _resetZoomToDefault : null,
            onTap: widget.onInteraction,
            child: Listener(
              onPointerSignal: _handlePagedPointerSignal,
              child: zoomableImage,
            ),
          ),
        );
      },
    );
  }
}
