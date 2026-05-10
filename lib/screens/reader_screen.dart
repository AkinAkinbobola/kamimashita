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
import '../providers/library_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/cover_card.dart';
import '../widgets/theme.dart';

enum ReaderFitMode { contain, fitWidth, fitHeight, originalSize }

enum _PagedScrollResetAnchor { top, bottom }

enum _PagedWheelEdge { top, bottom }

enum _ArchiveBoundary { beginning, end }

const double _trackpadPanSensitivity = 0.6;

bool get _showsReaderWindowControls {
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

bool _isTrackpadScrollEvent(PointerScrollEvent event) {
  return event.kind == PointerDeviceKind.trackpad;
}

bool _isCtrlPressed() {
  return HardwareKeyboard.instance.isControlPressed;
}

double _normalizePanZoomDelta(BuildContext context, double rawDeltaY) {
  final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  return -(rawDeltaY / devicePixelRatio) * _trackpadPanSensitivity;
}

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
  static const _keyboardScrollDuration = Duration(milliseconds: 150);
  static const _cursorHideDelay = Duration(seconds: 3);
  static const _overlayAnimationDuration = Duration(milliseconds: 200);

  late Future<_ReaderDocument> _documentFuture;
  final FocusNode _readerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  PageController? _pageController;
  Timer? _chromeHideTimer;
  Timer? _cursorHideTimer;
  Timer? _progressSyncTimer;

  bool _isControlsVisible = true;
  bool _autoHideChrome = true;
  bool _showSettingsPopover = false;
  bool _isHoveringControls = false;
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
  bool _isExitingReader = false;
  DateTime? _lastPagedWheelPageTurnAt;
  double _zoomLevel = 1.0;
  int _pagedScrollResetToken = 0;
  _PagedScrollResetAnchor _pagedScrollResetAnchor = _PagedScrollResetAnchor.top;
  ReaderFitMode _fitMode = ReaderFitMode.contain;
  List<String> _pageUrls = const [];
  List<GlobalKey> _pageKeys = const [];
  List<GlobalKey<_ReaderPageState>> _pagedPageStateKeys = const [];
  Map<String, ImageProvider<Object>> _pageImageProviders = {};
  double? _continuousAnimatedScrollTarget;
  bool _cursorVisible = true;
  _ArchiveBoundary? _armedArchiveBoundary;
  _ArchiveBoundary? _visibleArchiveBoundary;

  MouseCursor _activeCursor(MouseCursor normal) {
    return _cursorVisible ? normal : SystemMouseCursors.none;
  }

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
        _scheduleControlsHide();
        _scheduleCursorHide();
        _loadFullscreenState();
      }
    });
  }

  @override
  void dispose() {
    _chromeHideTimer?.cancel();
    _cursorHideTimer?.cancel();
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
        _zoomLevel = _clampZoomLevel(settings.readerZoomLevel);
        _isControlsVisible = true;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncModeViewport(_currentPage, animate: false);
      if (_autoHideChrome) {
        _scheduleControlsHide();
      } else {
        _chromeHideTimer?.cancel();
      }
    });

  }

  ReaderFitMode _readerFitModeFromStorage(String value) {
    return switch (value) {
      'fitWidth' => ReaderFitMode.fitWidth,
      'fitHeight' => ReaderFitMode.fitHeight,
      'originalSize' => ReaderFitMode.originalSize,
      _ => ReaderFitMode.contain,
    };
  }

  double _clampZoomLevel(double value) {
    return value.clamp(0.3, 5.0);
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
    _pagedPageStateKeys = List<GlobalKey<_ReaderPageState>>.generate(
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
    ref
        .read(libraryStateProvider)
        .upsertOnDeckEntry(
          archiveId: widget.archive.id,
          title: title,
          currentPage: currentPage,
          totalPages: totalPages,
        );
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

  void _scheduleCursorHide() {
    _cursorHideTimer?.cancel();
    _cursorHideTimer = Timer(_cursorHideDelay, () {
      if (!mounted || !_cursorVisible) {
        return;
      }
      setState(() {
        _cursorVisible = false;
      });
    });
  }

  void _handleReaderHover(PointerHoverEvent event) {
    if (!mounted) {
      return;
    }
    if (!_cursorVisible) {
      setState(() {
        _cursorVisible = true;
      });
    }
    _scheduleCursorHide();
  }

  void _handleReaderPointerDown(PointerDownEvent event) {
    if (!mounted) {
      return;
    }
    if (!_cursorVisible) {
      setState(() {
        _cursorVisible = true;
      });
    }
    _scheduleCursorHide();
  }

  void _scheduleControlsHide() {
    _chromeHideTimer?.cancel();
    if (!_autoHideChrome ||
        _showSettingsPopover ||
        _isHoveringControls ||
        !_isControlsVisible) {
      return;
    }
    _chromeHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !_autoHideChrome ||
          _showSettingsPopover ||
          _isHoveringControls) {
        return;
      }
      setState(() {
        _isControlsVisible = false;
      });
    });
  }

  void _setControlsHovering(bool value) {
    if (_isHoveringControls == value) {
      return;
    }
    _isHoveringControls = value;
    if (value) {
      _chromeHideTimer?.cancel();
      return;
    }
    _scheduleControlsHide();
  }

  void _toggleControls() {
    _chromeHideTimer?.cancel();
    setState(() {
      _isControlsVisible = !_isControlsVisible;
      if (!_isControlsVisible) {
        _showSettingsPopover = false;
      }
    });
    _scheduleControlsHide();
  }

  void _handleReaderToggleControlsTap() {
    if (!_cursorVisible) {
      setState(() {
        _cursorVisible = true;
      });
    }
    _scheduleCursorHide();
    _toggleControls();
  }

  void _closeSettingsPopover() {
    if (!_showSettingsPopover) {
      return;
    }
    setState(() {
      _showSettingsPopover = false;
    });
    _scheduleControlsHide();
  }

  void _toggleSettingsPopover() {
    setState(() {
      _showSettingsPopover = !_showSettingsPopover;
      _isControlsVisible = true;
    });
    _scheduleControlsHide();
  }

  void _retry() {
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
      _preparePagedScrollReset(
        _isReadingForwardTarget(clamped)
            ? _PagedScrollResetAnchor.top
            : _PagedScrollResetAnchor.bottom,
      );
      _pageController?.jumpToPage(clamped);
    }
  }

  bool _isReadingForwardTarget(int targetPage) {
    return _rightToLeft ? targetPage < _currentPage : targetPage > _currentPage;
  }

  void _preparePagedScrollReset(_PagedScrollResetAnchor anchor) {
    _pagedScrollResetToken += 1;
    _pagedScrollResetAnchor = anchor;
  }

  void _setZoomLevel(double value) {
    final clamped = _clampZoomLevel(value);
    if (_zoomLevel == clamped) {
      return;
    }
    setState(() {
      _zoomLevel = clamped;
    });
    unawaited(
      SettingsModel.instance.updateReaderPreferences(zoomLevel: clamped),
    );
  }

  void _adjustZoomLevel(double delta) {
    _setZoomLevel(_zoomLevel + delta);
  }

  void _resetZoomLevel() {
    _setZoomLevel(1.0);
  }

  double _continuousScrollStep() {
    if (_scrollController.hasClients) {
      return _scrollController.position.viewportDimension * 0.8;
    }

    return MediaQuery.sizeOf(context).height * 0.8;
  }

  bool get _usesCustomContinuousPointerScrolling {
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

  bool _applyContinuousScrollDelta(double deltaY) {
    if (deltaY == 0 || !_scrollController.hasClients) {
      return false;
    }

    _continuousAnimatedScrollTarget = null;
    final position = _scrollController.position;
    final targetOffset = (position.pixels + deltaY).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((targetOffset - position.pixels).abs() <= 0.5) {
      return false;
    }

    _scrollController.jumpTo(targetOffset);
    return true;
  }

  bool _applyAnimatedContinuousScrollDelta(double deltaY) {
    if (deltaY == 0 || !_scrollController.hasClients) {
      return false;
    }

    final position = _scrollController.position;
    final targetOffset =
        ((_continuousAnimatedScrollTarget ?? position.pixels) + deltaY).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if ((targetOffset - position.pixels).abs() <= 0.5) {
      return false;
    }

    _continuousAnimatedScrollTarget = targetOffset;
    _scrollController
        .animateTo(
          targetOffset,
          duration: _keyboardScrollDuration,
          curve: Curves.easeOut,
        )
        .whenComplete(() {
          if (!mounted || _continuousAnimatedScrollTarget != targetOffset) {
            return;
          }
          _continuousAnimatedScrollTarget = null;
        });
    return true;
  }

  bool _applyPagedKeyboardScroll(double deltaY) {
    if (_currentPage < 0 || _currentPage >= _pagedPageStateKeys.length) {
      return false;
    }

    return _pagedPageStateKeys[_currentPage].currentState?.handleKeyboardScroll(
          deltaY,
        ) ??
        false;
  }

  double _pagedKeyboardScrollStep() {
    if (_currentPage < 0 || _currentPage >= _pagedPageStateKeys.length) {
      return MediaQuery.sizeOf(context).height * 0.8;
    }

    return _pagedPageStateKeys[_currentPage].currentState
            ?.keyboardScrollStep() ??
        MediaQuery.sizeOf(context).height * 0.8;
  }

  void _handleContinuousPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }

    final deltaY = event.scrollDelta.dy;
    if (deltaY == 0) {
      return;
    }

    if (_isCtrlPressed()) {
      final zoomDelta = -deltaY / 600;
      _adjustZoomLevel(zoomDelta);
      return;
    }

    if (_isTrackpadScrollEvent(event)) {
      _applyContinuousScrollDelta(deltaY);
      return;
    }

    if (_usesCustomContinuousPointerScrolling) {
      _applyAnimatedContinuousScrollDelta(deltaY);
    }
  }

  void _handleContinuousPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (event.panDelta.dy.abs() <= event.panDelta.dx.abs()) {
      return;
    }

    final deltaY = _normalizePanZoomDelta(context, event.panDelta.dy);
    if (deltaY == 0) {
      return;
    }

    if (_isCtrlPressed()) {
      _adjustZoomLevel(-deltaY / 600);
      return;
    }

    _applyContinuousScrollDelta(deltaY);
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
      _handleArchiveBoundaryAttempt(_ArchiveBoundary.end, confirmed: fromWheel);
      return;
    }
    if (fromWheel && !_consumePagedWheelNavigationCooldown()) {
      return;
    }
    _clearArchiveBoundaryState();
    _goReadingForward(document);
  }

  void _goPreviousPage(_ReaderDocument document, {bool fromWheel = false}) {
    if (!_canGoReadingBackward(document.pageUrls.length)) {
      _handleArchiveBoundaryAttempt(
        _ArchiveBoundary.beginning,
        confirmed: fromWheel,
      );
      return;
    }
    if (fromWheel && !_consumePagedWheelNavigationCooldown()) {
      return;
    }
    _clearArchiveBoundaryState();
    _goReadingBackward(document);
  }

  void _handleArchiveBoundaryAttempt(
    _ArchiveBoundary boundary, {
    required bool confirmed,
  }) {
    if (_visibleArchiveBoundary == boundary) {
      return;
    }

    if (confirmed || _armedArchiveBoundary == boundary) {
      setState(() {
        _armedArchiveBoundary = null;
        _visibleArchiveBoundary = boundary;
      });
      return;
    }

    setState(() {
      _armedArchiveBoundary = boundary;
    });
  }

  void _clearArchiveBoundaryState() {
    if (_armedArchiveBoundary == null && _visibleArchiveBoundary == null) {
      return;
    }

    setState(() {
      _armedArchiveBoundary = null;
      _visibleArchiveBoundary = null;
    });
  }

  void _handleArchiveBoundaryBackToLibrary() {
    _clearArchiveBoundaryState();
    _exitReader();
  }

  void _setContinuousScroll(bool value) {
    if (_continuousScroll == value) {
      return;
    }
    final targetPage = _currentPage;
    const resetZoomLevel = 1.0;
    setState(() {
      _continuousScroll = value;
      _zoomLevel = resetZoomLevel;
    });
    unawaited(
      SettingsModel.instance.updateReaderPreferences(
        continuousScroll: value,
        zoomLevel: resetZoomLevel,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _syncModeViewport(targetPage, animate: false);
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
    if (_armedArchiveBoundary != null || _visibleArchiveBoundary != null) {
      _armedArchiveBoundary = null;
      _visibleArchiveBoundary = null;
    }
    if (_currentPage != index && mounted) {
      setState(() {
        _currentPage = index;
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
            ref
                .read(libraryStateProvider)
                .updateArchiveProgress(archiveId, queuedPage + 1);
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
  }

  Future<void> _exitReader() async {
    if (_isExitingReader) {
      return;
    }

    _isExitingReader = true;
    if (_supportsWindowFullscreen) {
      await windowManager.setFullScreen(false);
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _isFullscreen = false;
      _isExitingReader = true;
    });

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    setState(() {
      _isExitingReader = false;
    });
  }

  KeyEventResult _handleKeyEvent(KeyEvent event, _ReaderDocument document) {
    final isArrowEvent = event is KeyDownEvent || event is KeyRepeatEvent;
    if (!isArrowEvent && event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        return _applyPagedKeyboardScroll(-_pagedKeyboardScrollStep())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowRight:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        return _applyPagedKeyboardScroll(_pagedKeyboardScrollStep())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowUp:
        if (_continuousScroll) {
          return _applyAnimatedContinuousScrollDelta(-_continuousScrollStep())
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        return _applyPagedKeyboardScroll(-_pagedKeyboardScrollStep())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowDown:
        if (_continuousScroll) {
          return _applyAnimatedContinuousScrollDelta(_continuousScrollStep())
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        return _applyPagedKeyboardScroll(_pagedKeyboardScrollStep())
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.pageUp:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _goPreviousPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _goNextPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyA:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _goPreviousPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyD:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _goNextPage(document);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        if (_continuousScroll) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (HardwareKeyboard.instance.isShiftPressed) {
          _goPreviousPage(document);
        } else {
          _goNextPage(document);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _toggleControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (_visibleArchiveBoundary != null) {
          _clearArchiveBoundaryState();
          return KeyEventResult.handled;
        }
        if (_showSettingsPopover) {
          setState(() {
            _showSettingsPopover = false;
          });
          _scheduleControlsHide();
          return KeyEventResult.handled;
        }
        unawaited(_exitReader());
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = SettingsModel.instance.authHeader();
    final theme = Theme.of(context);

    return PopScope<void>(
      canPop: _isExitingReader,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_exitReader());
      },
      child: MouseRegion(
        cursor: _activeCursor(SystemMouseCursors.basic),
        onHover: _handleReaderHover,
        child: SelectionContainer.disabled(
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
            final controlsVisible = _isControlsVisible || _showSettingsPopover;
            final archiveBoundaryVisible = _visibleArchiveBoundary != null;
            final pageController =
                _pageController ??
                PageController(initialPage: document.initialPage);

            return Focus(
              focusNode: _readerFocusNode,
              autofocus: true,
              onKeyEvent: (node, event) => _handleKeyEvent(event, document),
              child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _handleReaderPointerDown,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black,
                          child: _continuousScroll
                              ? NotificationListener<ScrollNotification>(
                                  onNotification: (notification) {
                                    if (notification
                                            is ScrollUpdateNotification ||
                                        notification is ScrollEndNotification) {
                                      _scheduleVisiblePageUpdate();
                                    }
                                    return false;
                                  },
                                  child: Listener(
                                    behavior: HitTestBehavior.opaque,
                                    onPointerSignal:
                                        _handleContinuousPointerSignal,
                                    onPointerPanZoomUpdate:
                                        _handleContinuousPanZoomUpdate,
                                    child: Container(
                                      key: _scrollViewportKey,
                                      child: _Scrollbarless(
                                        child: ListView.builder(
                                          key: ValueKey('scroll-$_reloadToken'),
                                          controller: _scrollController,
                                          physics:
                                              _usesCustomContinuousPointerScrolling
                                              ? const NeverScrollableScrollPhysics()
                                              : null,
                                          cacheExtent:
                                              MediaQuery.sizeOf(
                                                context,
                                              ).height *
                                              1.5,
                                          itemCount: pageCount,
                                          itemBuilder: (context, index) {
                                            return KeyedSubtree(
                                              key: _pageKeys[index],
                                              child: _ReaderPage(
                                                imageProvider:
                                                    _pageImageProvider(
                                                      document.archive.id,
                                                      index + 1,
                                                      document.pageUrls[index],
                                                      headers,
                                                    ),
                                                pageNumber: index + 1,
                                                fitMode: ReaderFitMode.fitWidth,
                                                zoomEnabled: true,
                                                zoomLevel: _zoomLevel,
                                                continuousLayout: true,
                                                onZoomLevelChanged:
                                                    _setZoomLevel,
                                                onInteraction:
                                                    _handleReaderToggleControlsTap,
                                                onRetryRequested: _retry,
                                                mouseCursor: _activeCursor(
                                                  SystemMouseCursors.click,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : PageView.builder(
                                  key: ValueKey(
                                    'pageview-$_reloadToken-$_rightToLeft',
                                  ),
                                  controller: pageController,
                                  allowImplicitScrolling: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  reverse: _rightToLeft,
                                  itemCount: pageCount,
                                  onPageChanged: (index) {
                                    _setCurrentPage(index, document.archive.id);
                                  },
                                  itemBuilder: (context, index) {
                                    return _ReaderPage(
                                      key: _pagedPageStateKeys[index],
                                      imageProvider: _pageImageProvider(
                                        document.archive.id,
                                        index + 1,
                                        document.pageUrls[index],
                                        headers,
                                      ),
                                      pageNumber: index + 1,
                                      fitMode: _fitMode,
                                      zoomEnabled: true,
                                      zoomLevel: _zoomLevel,
                                      keepWarm:
                                          (index - _currentPage).abs() <= 1,
                                      isActive: index == _currentPage,
                                      pagedNavigationEnabled: true,
                                      pagedScrollResetToken:
                                          _pagedScrollResetToken,
                                      pagedScrollResetAnchor:
                                          _pagedScrollResetAnchor,
                                      onNextPageRequested: () => _goNextPage(
                                        document,
                                        fromWheel: false,
                                      ),
                                      onPreviousPageRequested: () =>
                                          _goPreviousPage(
                                            document,
                                            fromWheel: false,
                                          ),
                                      onNextPageFromWheelRequested: () =>
                                          _goNextPage(
                                            document,
                                            fromWheel: true,
                                          ),
                                      onPreviousPageFromWheelRequested: () =>
                                          _goPreviousPage(
                                            document,
                                            fromWheel: true,
                                          ),
                                      onZoomLevelChanged: _setZoomLevel,
                                      onToggleControlsRequested:
                                          _handleReaderToggleControlsTap,
                                      onInteraction: null,
                                      onRetryRequested: _retry,
                                      mouseCursor: _activeCursor(
                                        SystemMouseCursors.click,
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: MouseRegion(
                          cursor: _activeCursor(SystemMouseCursors.basic),
                          onEnter: (_) => _setControlsHovering(true),
                          onExit: (_) => _setControlsHovering(false),
                          child: IgnorePointer(
                            ignoring: !controlsVisible,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: controlsVisible ? 1 : 0,
                              child: SafeArea(
                                bottom: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    0,
                                  ),
                                  child: DragToMoveArea(
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
                                              mouseCursor: _activeCursor(
                                                SystemMouseCursors.click,
                                              ),
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
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: theme
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color: Colors.white,
                                                        ),
                                                  ),
                                                  Text(
                                                    '${_currentPage + 1} / $pageCount',
                                                    style: theme
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          color: Colors.white70,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            _ReaderBarButton(
                                              mouseCursor: _activeCursor(
                                                SystemMouseCursors.click,
                                              ),
                                              tooltip: 'Reader settings',
                                              icon: Icons.tune_rounded,
                                              onPressed: _toggleSettingsPopover,
                                              active: _showSettingsPopover,
                                            ),
                                            if (_supportsWindowFullscreen) ...[
                                              const SizedBox(width: 4),
                                              _ReaderBarButton(
                                                mouseCursor: _activeCursor(
                                                  SystemMouseCursors.click,
                                                ),
                                                tooltip: _isFullscreen
                                                    ? 'Exit fullscreen'
                                                    : 'Fullscreen',
                                                icon: _isFullscreen
                                                    ? Icons
                                                          .fullscreen_exit_rounded
                                                    : Icons.fullscreen_rounded,
                                                onPressed: _toggleFullscreen,
                                                active: _isFullscreen,
                                              ),
                                            ],
                                            const SizedBox(width: 4),
                                            _ReaderBarButton(
                                              mouseCursor: _activeCursor(
                                                SystemMouseCursors.click,
                                              ),
                                              tooltip: 'Reload pages',
                                              icon: Icons.refresh_rounded,
                                              onPressed: _retry,
                                            ),
                                            if (_showsReaderWindowControls) ...[
                                              const SizedBox(width: 4),
                                              _ReaderBarButton(
                                                mouseCursor: _activeCursor(
                                                  SystemMouseCursors.click,
                                                ),
                                                tooltip: 'Minimize window',
                                                icon: Icons.horizontal_rule_rounded,
                                                onPressed: () async {
                                                  await windowManager.minimize();
                                                },
                                              ),
                                              const SizedBox(width: 4),
                                              _ReaderBarButton(
                                                mouseCursor: _activeCursor(
                                                  SystemMouseCursors.click,
                                                ),
                                                tooltip: 'Close window',
                                                icon: Icons.close_rounded,
                                                onPressed: () async {
                                                  await windowManager.close();
                                                },
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
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
                        child: MouseRegion(
                          cursor: _activeCursor(SystemMouseCursors.basic),
                          onEnter: (_) => _setControlsHovering(true),
                          onExit: (_) => _setControlsHovering(false),
                          child: IgnorePointer(
                            ignoring: !controlsVisible,
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: controlsVisible ? 1 : 0,
                              child: SafeArea(
                                top: false,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    12,
                                  ),
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
                                            mouseCursor: _activeCursor(
                                              SystemMouseCursors.click,
                                            ),
                                            tooltip: 'Previous page',
                                            icon: Icons.chevron_left_rounded,
                                            onPressed:
                                                _canGoReadingBackward(pageCount)
                                                ? () => _goReadingBackward(
                                                    document,
                                                  )
                                                : null,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: SliderTheme(
                                              data: SliderTheme.of(context)
                                                  .copyWith(
                                                    trackHeight: 3,
                                                    overlayShape:
                                                        SliderComponentShape
                                                            .noOverlay,
                                                    activeTrackColor:
                                                        AppTheme.crimson,
                                                    inactiveTrackColor:
                                                        Colors.white24,
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
                                                ?.copyWith(
                                                  color: Colors.white70,
                                                ),
                                          ),
                                          const SizedBox(width: 12),
                                          _ReaderZoomControl(
                                            zoomLevel: _zoomLevel,
                                            onZoomOut: () =>
                                                _adjustZoomLevel(-0.1),
                                            onZoomReset: _resetZoomLevel,
                                            onZoomIn: () =>
                                                _adjustZoomLevel(0.1),
                                            mouseCursor: _activeCursor(
                                              SystemMouseCursors.click,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _ReaderBarButton(
                                            mouseCursor: _activeCursor(
                                              SystemMouseCursors.click,
                                            ),
                                            tooltip: 'Next page',
                                            icon: Icons.chevron_right_rounded,
                                            onPressed:
                                                _canGoReadingForward(pageCount)
                                                ? () => _goReadingForward(
                                                    document,
                                                  )
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
                      ),
                      if (_showSettingsPopover)
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: _activeCursor(SystemMouseCursors.click),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _closeSettingsPopover,
                              child: const SizedBox.expand(),
                            ),
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
                              mouseCursor: _activeCursor(
                                SystemMouseCursors.click,
                              ),
                              onFitModeChanged: (mode) {
                                const resetZoomLevel = 1.0;
                                setState(() {
                                  _fitMode = mode;
                                  _zoomLevel = resetZoomLevel;
                                });
                                unawaited(
                                  SettingsModel.instance
                                      .updateReaderPreferences(
                                        fitMode: mode.name,
                                        zoomLevel: resetZoomLevel,
                                      ),
                                );
                              },
                              onContinuousScrollChanged: _setContinuousScroll,
                              onRightToLeftChanged: (value) {
                                setState(() {
                                  _rightToLeft = value;
                                });
                                unawaited(
                                  SettingsModel.instance
                                      .updateReaderPreferences(
                                        rightToLeft: value,
                                      ),
                                );
                              },
                              onAutoHideChanged: (value) {
                                setState(() {
                                  _autoHideChrome = value;
                                });
                                unawaited(
                                  SettingsModel.instance
                                      .updateReaderPreferences(
                                        autoHideChrome: value,
                                      ),
                                );
                                if (value) {
                                  _scheduleControlsHide();
                                } else {
                                  _chromeHideTimer?.cancel();
                                }
                              },
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !archiveBoundaryVisible,
                          child: AnimatedOpacity(
                            duration: _overlayAnimationDuration,
                            opacity: archiveBoundaryVisible ? 1 : 0,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: MouseRegion(
                                    cursor: _activeCursor(
                                      SystemMouseCursors.click,
                                    ),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _clearArchiveBoundaryState,
                                      child: const ColoredBox(
                                        color: Color(0x66000000),
                                      ),
                                    ),
                                  ),
                                ),
                                SafeArea(
                                  child: Align(
                                    alignment:
                                        _visibleArchiveBoundary ==
                                            _ArchiveBoundary.beginning
                                        ? Alignment.topCenter
                                        : Alignment.bottomCenter,
                                    child: AnimatedSlide(
                                      duration: _overlayAnimationDuration,
                                      curve: Curves.easeOutCubic,
                                      offset: archiveBoundaryVisible
                                          ? Offset.zero
                                          : _visibleArchiveBoundary ==
                                                _ArchiveBoundary.beginning
                                          ? const Offset(0, -0.18)
                                          : const Offset(0, 0.18),
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: _ArchiveBoundaryCard(
                                          archive: document.archive,
                                          boundary:
                                              _visibleArchiveBoundary ??
                                              _ArchiveBoundary.end,
                                          mouseCursor: _activeCursor(
                                            SystemMouseCursors.click,
                                          ),
                                          onDismiss: _clearArchiveBoundaryState,
                                          onBackToLibrary:
                                              _handleArchiveBoundaryBackToLibrary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            );
            },
          ),
          ),
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

class _ArchiveBoundaryCard extends StatelessWidget {
  const _ArchiveBoundaryCard({
    required this.archive,
    required this.boundary,
    required this.mouseCursor,
    required this.onDismiss,
    required this.onBackToLibrary,
  });

  final Archive archive;
  final _ArchiveBoundary boundary;
  final MouseCursor mouseCursor;
  final VoidCallback onDismiss;
  final VoidCallback onBackToLibrary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBeginning = boundary == _ArchiveBoundary.beginning;

    return MouseRegion(
      cursor: mouseCursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xEE101217),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF252B36), width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x44000000),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
          ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 88,
                  height: 124,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ArchiveThumbnail(archive: archive),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        archive.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isBeginning
                            ? "You're at the beginning"
                            : "You've reached the end",
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isBeginning
                            ? 'There are no previous pages in this archive.'
                            : 'There are no more pages in this archive.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton(
                            onPressed: onBackToLibrary,
                            child: const Text('Back to Library'),
                          ),
                          TextButton(
                            onPressed: onDismiss,
                            child: const Text('Dismiss'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderBarButton extends StatefulWidget {
  const _ReaderBarButton({
    required this.mouseCursor,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final MouseCursor mouseCursor;
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
        cursor: enabled ? widget.mouseCursor : SystemMouseCursors.none,
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
    required this.mouseCursor,
    required this.onFitModeChanged,
    required this.onContinuousScrollChanged,
    required this.onRightToLeftChanged,
    required this.onAutoHideChanged,
  });

  final ReaderFitMode fitMode;
  final bool continuousScroll;
  final bool rightToLeft;
  final bool autoHideChrome;
  final MouseCursor mouseCursor;
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
                            mouseCursor: mouseCursor,
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
                    mouseCursor: mouseCursor,
                  ),
                  _ReaderTextToggle(
                    label: 'Scroll',
                    selected: continuousScroll,
                    onTap: () => onContinuousScrollChanged(true),
                    accentColor: _accent,
                    mouseCursor: mouseCursor,
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
                    mouseCursor: mouseCursor,
                  ),
                  _ReaderTextToggle(
                    label: 'Right to left',
                    selected: rightToLeft,
                    onTap: () => onRightToLeftChanged(true),
                    accentColor: _accent,
                    mouseCursor: mouseCursor,
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
    required this.mouseCursor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color accentColor;
  final MouseCursor mouseCursor;

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
      cursor: widget.mouseCursor,
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

class _ReaderZoomControl extends StatelessWidget {
  const _ReaderZoomControl({
    required this.zoomLevel,
    required this.onZoomOut,
    required this.onZoomReset,
    required this.onZoomIn,
    required this.mouseCursor,
  });

  final double zoomLevel;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;
  final VoidCallback onZoomIn;
  final MouseCursor mouseCursor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percentage = (zoomLevel * 100).round();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF161A21),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF252B36), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ReaderZoomButton(
              tooltip: 'Zoom out',
              label: '-',
              onPressed: onZoomOut,
              mouseCursor: mouseCursor,
            ),
            MouseRegion(
              cursor: mouseCursor,
              child: GestureDetector(
                onTap: onZoomReset,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(
                    '$percentage%',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            _ReaderZoomButton(
              tooltip: 'Zoom in',
              label: '+',
              onPressed: onZoomIn,
              mouseCursor: mouseCursor,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReaderZoomButton extends StatefulWidget {
  const _ReaderZoomButton({
    required this.tooltip,
    required this.label,
    required this.onPressed,
    required this.mouseCursor,
  });

  final String tooltip;
  final String label;
  final VoidCallback onPressed;
  final MouseCursor mouseCursor;

  @override
  State<_ReaderZoomButton> createState() => _ReaderZoomButtonState();
}

class _ReaderZoomButtonState extends State<_ReaderZoomButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _hovered ? Colors.white : Colors.white70;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.mouseCursor,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
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
    this.zoomLevel = 1.0,
    this.continuousLayout = false,
    this.keepWarm = false,
    this.isActive = false,
    this.pagedNavigationEnabled = false,
    this.pagedScrollResetToken,
    this.pagedScrollResetAnchor,
    this.onNextPageRequested,
    this.onPreviousPageRequested,
    this.onNextPageFromWheelRequested,
    this.onPreviousPageFromWheelRequested,
    this.onZoomLevelChanged,
    this.onToggleControlsRequested,
    required this.onInteraction,
    required this.onRetryRequested,
    required this.mouseCursor,
  });

  final ImageProvider<Object> imageProvider;
  final int pageNumber;
  final ReaderFitMode fitMode;
  final bool zoomEnabled;
  final double zoomLevel;
  final bool continuousLayout;
  final bool keepWarm;
  final bool isActive;
  final bool pagedNavigationEnabled;
  final int? pagedScrollResetToken;
  final _PagedScrollResetAnchor? pagedScrollResetAnchor;
  final VoidCallback? onNextPageRequested;
  final VoidCallback? onPreviousPageRequested;
  final VoidCallback? onNextPageFromWheelRequested;
  final VoidCallback? onPreviousPageFromWheelRequested;
  final ValueChanged<double>? onZoomLevelChanged;
  final VoidCallback? onToggleControlsRequested;
  final VoidCallback? onInteraction;
  final VoidCallback onRetryRequested;
  final MouseCursor mouseCursor;

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

class _ReaderPageState extends State<_ReaderPage>
    with AutomaticKeepAliveClientMixin {
  static const _desktopGestureDevices = <PointerDeviceKind>{
    PointerDeviceKind.mouse,
  };

  static const _keyboardScrollDuration = Duration(milliseconds: 150);
  static const _edgePushMinDelta = 14.0;
  static const _edgePushMinInterval = Duration(milliseconds: 85);

  final ScrollController _verticalScrollController = ScrollController();
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  ImageInfo? _imageInfo;
  Object? _imageError;
  _PagedWheelEdge? _armedWheelEdge;
  DateTime? _lastWheelEdgePushAt;
  _PagedScrollResetAnchor? _pendingPagedScrollResetAnchor;
  double? _animatedScrollTarget;

  int get _pagedScrollResetToken => widget.pagedScrollResetToken ?? 0;

  _PagedScrollResetAnchor get _pagedScrollResetAnchor {
    return widget.pagedScrollResetAnchor ?? _PagedScrollResetAnchor.top;
  }

  @override
  bool get wantKeepAlive => widget.keepWarm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant _ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) {
      _resolveImage(force: true);
    }
    if (oldWidget.keepWarm != widget.keepWarm) {
      updateKeepAlive();
    }
    if (widget.pagedNavigationEnabled &&
        widget.isActive &&
        oldWidget.pagedScrollResetToken != _pagedScrollResetToken) {
      _pendingPagedScrollResetAnchor = _pagedScrollResetAnchor;
      _schedulePagedScrollReset();
    }
    if (!widget.isActive || oldWidget.isActive != widget.isActive) {
      _resetPagedWheelEdgeArming();
    }
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageStreamListener != null) {
      _imageStream!.removeListener(_imageStreamListener!);
    }
    _verticalScrollController.dispose();
    super.dispose();
  }

  double get zoomLevel => widget.zoomLevel.clamp(0.3, 5.0);

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
        if (_pendingPagedScrollResetAnchor != null) {
          _schedulePagedScrollReset();
        }
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

  void _resetZoom() {
    widget.onZoomLevelChanged?.call(1.0);
  }

  void _schedulePagedScrollReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyPendingPagedScrollReset();
    });
  }

  void _applyPendingPagedScrollReset() {
    final anchor = _pendingPagedScrollResetAnchor;
    if (!mounted ||
        anchor == null ||
        !widget.pagedNavigationEnabled ||
        !widget.isActive ||
        !_verticalScrollController.hasClients) {
      return;
    }

    if (anchor == _PagedScrollResetAnchor.bottom && _imageInfo == null) {
      _schedulePagedScrollReset();
      return;
    }

    _pendingPagedScrollResetAnchor = null;
    _resetPagedWheelEdgeArming();
    _verticalScrollController.jumpTo(
      anchor == _PagedScrollResetAnchor.top
          ? _verticalScrollController.position.minScrollExtent
          : _verticalScrollController.position.maxScrollExtent,
    );
  }

  bool get _canPanZoomedImage => zoomLevel > 1.01;

  void _resetZoomToDefault() {
    if (!widget.zoomEnabled) {
      return;
    }
    _resetZoom();
  }

  void _handlePagedViewportTap(TapUpDetails details, Size viewportSize) {
    final ratio = viewportSize.width <= 0
        ? 0.5
        : details.localPosition.dx / viewportSize.width;
    if (_canPanZoomedImage) {
      if (ratio >= 0.33 && ratio <= 0.67) {
        widget.onToggleControlsRequested?.call();
      }
      return;
    }
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

    if (_isCtrlPressed() && widget.zoomEnabled) {
      final zoomDelta = -deltaY / 600;
      final nextZoom = (widget.zoomLevel + zoomDelta).clamp(0.3, 5.0);
      widget.onZoomLevelChanged?.call(nextZoom);
      return;
    }

    if (_isTrackpadScrollEvent(event)) {
      _applyPagedPixelScroll(deltaY);
      return;
    }

    if (!widget.pagedNavigationEnabled) {
      return;
    }

    _handlePagedWheelScroll(deltaY);
  }

  void _handlePagedPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (event.panDelta.dy.abs() <= event.panDelta.dx.abs()) {
      return;
    }

    final deltaY = _normalizePanZoomDelta(context, event.panDelta.dy);
    if (deltaY == 0) {
      return;
    }

    if (_isCtrlPressed() && widget.zoomEnabled) {
      final zoomDelta = -deltaY / 600;
      final nextZoom = (widget.zoomLevel + zoomDelta).clamp(0.3, 5.0);
      widget.onZoomLevelChanged?.call(nextZoom);
      return;
    }

    _applyPagedPixelScroll(deltaY);
  }

  bool handleKeyboardScroll(double deltaY) {
    return _applyPagedKeyboardDelta(deltaY);
  }

  double keyboardScrollStep() {
    if (_verticalScrollController.hasClients) {
      return _verticalScrollController.position.viewportDimension * 0.8;
    }

    return MediaQuery.sizeOf(context).height * 0.8;
  }

  bool _applyPagedPixelScroll(double deltaY) {
    if (!widget.pagedNavigationEnabled) {
      return false;
    }

    _animatedScrollTarget = null;
    final direction = deltaY > 0 ? _PagedWheelEdge.bottom : _PagedWheelEdge.top;
    _resetPagedWheelEdgeArmingIfDirectionChanged(direction);

    if (!_verticalScrollController.hasClients) {
      _handlePagedWheelEdgePush(direction, deltaY.abs());
      return true;
    }

    final position = _verticalScrollController.position;
    final currentOffset = position.pixels;
    final targetOffset = (currentOffset + deltaY).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if ((targetOffset - currentOffset).abs() > 0.5) {
      _verticalScrollController.jumpTo(targetOffset);
      final hitEdge = direction == _PagedWheelEdge.bottom
          ? targetOffset >= position.maxScrollExtent - 0.5
          : targetOffset <= position.minScrollExtent + 0.5;
      if (!hitEdge) {
        _resetPagedWheelEdgeArming();
      }
      return true;
    }

    _handlePagedWheelEdgePush(direction, deltaY.abs());
    return true;
  }

  bool _applyAnimatedScrollDelta(double deltaY) {
    if (!widget.pagedNavigationEnabled) {
      return false;
    }

    final direction = deltaY > 0 ? _PagedWheelEdge.bottom : _PagedWheelEdge.top;
    _resetPagedWheelEdgeArmingIfDirectionChanged(direction);

    if (!_verticalScrollController.hasClients) {
      _handlePagedWheelEdgePush(direction, deltaY.abs());
      _animatedScrollTarget = null;
      return true;
    }

    final position = _verticalScrollController.position;
    final targetOffset = ((_animatedScrollTarget ?? position.pixels) + deltaY)
        .clamp(position.minScrollExtent, position.maxScrollExtent);

    if ((targetOffset - position.pixels).abs() > 0.5) {
      _animatedScrollTarget = targetOffset;
      final hitEdge = direction == _PagedWheelEdge.bottom
          ? targetOffset >= position.maxScrollExtent - 0.5
          : targetOffset <= position.minScrollExtent + 0.5;
      if (!hitEdge) {
        _resetPagedWheelEdgeArming();
      }
      _verticalScrollController
          .animateTo(
            targetOffset,
            duration: _keyboardScrollDuration,
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            if (!mounted || _animatedScrollTarget != targetOffset) {
              return;
            }
            _animatedScrollTarget = null;
          });
      return true;
    }

    _animatedScrollTarget = null;
    _handlePagedWheelEdgePush(direction, deltaY.abs());
    return true;
  }

  bool _applyPagedKeyboardDelta(double deltaY) {
    if (!widget.pagedNavigationEnabled) {
      return false;
    }

    _animatedScrollTarget = null;
    _resetPagedWheelEdgeArming();
    final direction = deltaY > 0 ? _PagedWheelEdge.bottom : _PagedWheelEdge.top;

    if (!_verticalScrollController.hasClients) {
      _triggerKeyboardPageTurn(direction);
      return true;
    }

    final position = _verticalScrollController.position;
    final currentOffset = position.pixels;
    final targetOffset = (currentOffset + deltaY).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    if ((targetOffset - currentOffset).abs() > 0.5) {
      _verticalScrollController.animateTo(
        targetOffset,
        duration: _keyboardScrollDuration,
        curve: Curves.easeOut,
      );
      return true;
    }

    _triggerKeyboardPageTurn(direction);
    return true;
  }

  void _triggerKeyboardPageTurn(_PagedWheelEdge direction) {
    if (direction == _PagedWheelEdge.bottom) {
      widget.onNextPageRequested?.call();
    } else {
      widget.onPreviousPageRequested?.call();
    }
  }

  void _handlePagedWheelScroll(double deltaY) {
    _applyAnimatedScrollDelta(deltaY);
  }

  void _handlePagedWheelEdgePush(_PagedWheelEdge direction, double delta) {
    if (!_acceptsPagedWheelEdgePush(delta)) {
      return;
    }

    if (_armedWheelEdge == direction) {
      _resetPagedWheelEdgeArming();
      if (direction == _PagedWheelEdge.bottom) {
        widget.onNextPageFromWheelRequested?.call();
      } else {
        widget.onPreviousPageFromWheelRequested?.call();
      }
      return;
    }

    _armedWheelEdge = direction;
    _lastWheelEdgePushAt = DateTime.now();
  }

  bool _acceptsPagedWheelEdgePush(double delta) {
    if (delta < _edgePushMinDelta) {
      return false;
    }

    final now = DateTime.now();
    if (_lastWheelEdgePushAt != null &&
        now.difference(_lastWheelEdgePushAt!) < _edgePushMinInterval) {
      return false;
    }

    return true;
  }

  void _resetPagedWheelEdgeArmingIfDirectionChanged(_PagedWheelEdge direction) {
    if (_armedWheelEdge != null && _armedWheelEdge != direction) {
      _resetPagedWheelEdgeArming();
    }
  }

  void _resetPagedWheelEdgeArming() {
    _armedWheelEdge = null;
    _lastWheelEdgePushAt = null;
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

  ({Size baseSize, Alignment alignment}) _resolveImageLayout(
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

    final fitModeScale = switch (widget.continuousLayout
        ? ReaderFitMode.fitWidth
        : widget.fitMode) {
      ReaderFitMode.contain => math.min(widthScale, heightScale),
      ReaderFitMode.fitWidth => widthScale,
      ReaderFitMode.fitHeight => heightScale,
      ReaderFitMode.originalSize => math.min(
        1.0,
        math.min(widthScale, heightScale),
      ),
    };

    final safeScale = fitModeScale.isFinite && fitModeScale > 0
        ? fitModeScale
        : 1.0;
    final baseSize = Size(
      intrinsic.width * safeScale,
      intrinsic.height * safeScale,
    );
    final alignment = widget.continuousLayout
        ? Alignment.topCenter
        : baseSize.height > viewport.height + 1
        ? Alignment.topCenter
        : Alignment.center;
    return (baseSize: baseSize, alignment: alignment);
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
    final finalSize = Size(
      layout.baseSize.width * zoomLevel,
      layout.baseSize.height * zoomLevel,
    );
    final widthClampScale = finalSize.width > viewport.width
        ? viewport.width / finalSize.width
        : 1.0;
    final displayWidth = finalSize.width * widthClampScale;
    final displayHeight = finalSize.height * widthClampScale;
    final contentWidth = viewport.width;
    final contentHeight = widget.continuousLayout
        ? displayHeight
        : math.max(viewport.height, displayHeight);
    final image = RawImage(
      image: _imageInfo!.image,
      scale: _imageInfo!.scale,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );

    return SizedBox(
      width: contentWidth,
      height: contentHeight,
      child: Align(
        alignment: layout.alignment,
        child: SizedBox(
          width: displayWidth,
          height: displayHeight,
          child: image,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = _effectiveViewportSize(constraints);
        final image = _buildImage(constraints);
        final zoomableImage = ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            controller: _verticalScrollController,
            physics: widget.pagedNavigationEnabled
                ? const NeverScrollableScrollPhysics()
                : null,
            scrollDirection: Axis.vertical,
            child: image,
          ),
        );

        if (widget.continuousLayout) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            child: MouseRegion(
              cursor: widget.mouseCursor,
              child: GestureDetector(
                supportedDevices: _desktopGestureDevices,
                onDoubleTap: widget.zoomEnabled ? _resetZoomToDefault : null,
                onTap: widget.onInteraction,
                child: image,
              ),
            ),
          );
        }

        if (widget.pagedNavigationEnabled) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: _handlePagedPointerSignal,
              onPointerPanZoomUpdate: _handlePagedPanZoomUpdate,
              child: MouseRegion(
                cursor: widget.mouseCursor,
                child: GestureDetector(
                  supportedDevices: _desktopGestureDevices,
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: widget.zoomEnabled ? _resetZoomToDefault : null,
                  onTapUp: (details) =>
                      _handlePagedViewportTap(details, viewportSize),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      zoomableImage,
                      Align(
                        alignment: Alignment.center,
                        child: FractionallySizedBox(
                          widthFactor: 0.34,
                          heightFactor: 1,
                          child: MouseRegion(
                            cursor: widget.mouseCursor,
                            child: GestureDetector(
                              supportedDevices: _desktopGestureDevices,
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onToggleControlsRequested,
                              onDoubleTap: widget.zoomEnabled
                                  ? _resetZoomToDefault
                                  : null,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
          child: MouseRegion(
            cursor: widget.mouseCursor,
            child: GestureDetector(
              supportedDevices: _desktopGestureDevices,
              onDoubleTap: widget.zoomEnabled ? _resetZoomToDefault : null,
              onTap: widget.onInteraction,
              child: Listener(
                onPointerSignal: _handlePagedPointerSignal,
                child: zoomableImage,
              ),
            ),
          ),
        );
      },
    );
  }
}
