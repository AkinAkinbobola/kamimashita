import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../api/lanraragi_client.dart';
import '../models/archive.dart';
import '../models/library_sort_option.dart';
import '../providers/library_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/app_strings.dart';
import '../widgets/cover_card.dart';
import '../widgets/theme.dart';
import '../widgets/window_controls.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

/// Main library, search, and archive-entry screen for the app.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryRefreshSnapshot {
  const _LibraryRefreshSnapshot({
    required this.items,
    required this.nextStart,
    required this.hasMore,
    required this.recordsFiltered,
    required this.archiveCount,
  });

  final List<Archive> items;
  final int nextStart;
  final bool hasMore;
  final int? recordsFiltered;
  final int? archiveCount;
}

class _LibraryHistoryEntry {
  const _LibraryHistoryEntry({
    required this.searchQuery,
    required this.selectedCategoryId,
    required this.sortField,
    required this.sortOrder,
    required this.newOnly,
    required this.untagged,
    required this.hideCompleted,
  });

  final String searchQuery;
  final String? selectedCategoryId;
  final String sortField;
  final String sortOrder;
  final bool newOnly;
  final bool untagged;
  final bool hideCompleted;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LibraryHistoryEntry &&
            searchQuery == other.searchQuery &&
            selectedCategoryId == other.selectedCategoryId &&
            sortField == other.sortField &&
            sortOrder == other.sortOrder &&
            newOnly == other.newOnly &&
            untagged == other.untagged &&
            hideCompleted == other.hideCompleted;
  }

  @override
  int get hashCode => Object.hash(
    searchQuery,
    selectedCategoryId,
    sortField,
    sortOrder,
    newOnly,
    untagged,
    hideCompleted,
  );
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with WindowListener {
  static const _focusRevalidateDebounce = Duration(milliseconds: 500);
  static const _focusRevalidateCooldown = Duration(seconds: 30);
  static const String _archiveRatingPrefix = 'rating:';
  static const int _libraryHistoryLimit = 20;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  late final ProviderSubscription<Object> _libraryRefreshSubscription;
  Timer? _focusRevalidateTimer;
  List<Archive> _items = const [];
  List<LanraragiTagStat> _tagStats = const [];
  List<_SearchSuggestion> _suggestions = const [];
  int _highlightedSuggestionIndex = -1;
  bool _isInitialLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _nextStart = 0;
  String _activeQuery = '';
  Object? _loadError;
  Object? _loadMoreError;
  String? _tagStatsCacheKey;
  bool _isLoadingTagStats = false;
  String? _categoriesCacheKey;
  bool _isLoadingCategories = false;
  int _reloadGeneration = 0;
  List<LanraragiCategory> _categories = const [];
  String? _selectedCategoryId;
  LibrarySortOption _selectedSort = LibrarySortOption.title;
  String _sortOrder = 'asc';
  bool _newOnly = false;
  bool _untaggedOnly = false;
  bool _hideCompleted = false;
  String _settingsConnectionKey = '';
  int? _filteredResultCount;
  List<OnDeckEntry> _sidebarOnDeckEntries = const [];
  bool _isLoadingOnDeck = false;
  String? _onDeckMessage;
  bool _onDeckMessageIsError = false;
  bool _isPickingRandom = false;
  String? _randomPickMessage;
  bool _randomPickMessageIsError = false;
  Archive? _selectedArchive;
  List<LanraragiCategory> _selectedArchiveCategories = const [];
  bool _isLoadingSelectedArchiveCategories = false;
  bool _isUpdatingSelectedArchiveCategories = false;
  bool _isUpdatingSelectedArchiveRating = false;
  bool _isDeletingSelectedArchive = false;
  String? _selectedArchiveCategoryMessage;
  bool _selectedArchiveCategoryMessageIsError = false;
  bool _isRefreshRevalidating = false;
  bool _isBackgroundLibraryRefreshActive = false;
  DateTime? _lastSuccessfulFocusRevalidationAt;
  bool _didApplyPersistedLibraryFilters = false;
  bool _didRunInitialLibraryLoad = false;
  final List<_LibraryHistoryEntry> _libraryHistory = <_LibraryHistoryEntry>[];

  bool get _isDetailsOpen => _selectedArchive != null;

  bool get _hasActiveLibraryFilters {
    return _selectedCategoryId != null ||
        _selectedSort.id != LibrarySortOption.title.id ||
        _sortOrder != 'asc' ||
        _newOnly ||
        _untaggedOnly ||
        _hideCompleted;
  }

  bool get _isAtDefaultLibraryState {
    return _activeQuery.isEmpty &&
        !_hasActiveLibraryFilters &&
        _libraryHistory.isEmpty;
  }

  LibraryState get _libraryState => ref.read(libraryStateProvider);

  _LibraryHistoryEntry get _currentLibraryHistoryEntry => _LibraryHistoryEntry(
    searchQuery: _activeQuery,
    selectedCategoryId: _selectedCategoryId,
    sortField: _selectedSort.id,
    sortOrder: _sortOrder,
    newOnly: _newOnly,
    untagged: _untaggedOnly,
    hideCompleted: _hideCompleted,
  );

  void _pushLibraryHistoryIfNeeded(_LibraryHistoryEntry nextState) {
    final currentState = _currentLibraryHistoryEntry;
    if (currentState == nextState) {
      return;
    }

    setState(() {
      _libraryHistory.add(currentState);
      if (_libraryHistory.length > _libraryHistoryLimit) {
        _libraryHistory.removeAt(0);
      }
    });
  }

  void _restorePreviousLibraryState() {
    if (_libraryHistory.isEmpty) {
      return;
    }

    final previousState = _libraryHistory.removeLast();
    _controller.value = TextEditingValue(
      text: previousState.searchQuery,
      selection: TextSelection.collapsed(
        offset: previousState.searchQuery.length,
      ),
    );

    setState(() {
      _selectedCategoryId = previousState.selectedCategoryId;
      _selectedSort = LibrarySortOption.fromId(previousState.sortField);
      _sortOrder = previousState.sortOrder == 'desc' ? 'desc' : 'asc';
      _newOnly = previousState.newOnly;
      _untaggedOnly = previousState.untagged;
      _hideCompleted = previousState.hideCompleted;
      _suggestions = const [];
      _highlightedSuggestionIndex = -1;
    });

    _reloadLibrary(query: previousState.searchQuery);
  }

  void _handleLibraryStateChanged() {
    if (!mounted) {
      return;
    }

    final libraryState = ref.read(libraryStateProvider);
    final nextItems = libraryState.items;
    final nextOnDeckEntries = libraryState.onDeckEntries;
    final currentSelectedArchive = _selectedArchive;
    final nextSelectedArchive = currentSelectedArchive == null
        ? null
        : nextItems.firstWhere(
            (archive) => archive.id == currentSelectedArchive.id,
            orElse: () => currentSelectedArchive,
          );

    if (listEquals(_items, nextItems) &&
        listEquals(_sidebarOnDeckEntries, nextOnDeckEntries) &&
        identical(_selectedArchive, nextSelectedArchive)) {
      return;
    }

    setState(() {
      _items = nextItems;
      _sidebarOnDeckEntries = nextOnDeckEntries;
      _selectedArchive = nextSelectedArchive;
    });
  }

  @override
  void initState() {
    super.initState();
    if (desktopWindowControlsEnabled) {
      windowManager.addListener(this);
    }
    _libraryRefreshSubscription = ref.listenManual<Object>(libraryProvider, (
      previous,
      next,
    ) {
      if (!mounted || !SettingsModel.instance.isValid) {
        return;
      }
      _reloadLibrary();
    });
    ref.read(libraryStateProvider).addListener(_handleLibraryStateChanged);
    SettingsModel.instance.addListener(_onSettingsChanged);
    _controller.addListener(_onQueryChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeRunInitialLibraryLoad();
    });
  }

  @override
  void onWindowFocus() {
    if (!mounted || !SettingsModel.instance.isValid) {
      return;
    }
    _focusRevalidateTimer?.cancel();
    _focusRevalidateTimer = Timer(_focusRevalidateDebounce, () {
      unawaited(_revalidateLibraryOnFocus());
    });
  }

  void _onSettingsChanged() {
    final settings = SettingsModel.instance;
    final nextKey = '${settings.serverUrl}|${settings.apiKey}';
    final connectionChanged = nextKey != _settingsConnectionKey;

    if (!_didApplyPersistedLibraryFilters && settings.isLoaded) {
      _applyPersistedLibraryFilters(settings);
    }

    if (!_didRunInitialLibraryLoad && settings.isLoaded) {
      _didRunInitialLibraryLoad = true;
      if (settings.isValid) {
        _settingsConnectionKey = nextKey;
        _loadCategories();
        _refreshOnDeck();
        _reloadLibrary();
        return;
      }
    }

    setState(() {});

    if (settings.isValid) {
      _settingsConnectionKey = nextKey;
      if (settings.useLocalOnDeckFallback) {
        _applyLocalOnDeckFallback();
      } else if (connectionChanged) {
        _refreshOnDeck();
      }
      if (!connectionChanged) {
        return;
      }
      _loadCategories();
      _refreshOnDeck();
      _reloadLibrary();
    } else {
      _focusRevalidateTimer?.cancel();
      _settingsConnectionKey = '';
      setState(() {
        _items = const [];
        _loadError = null;
        _loadMoreError = null;
        _hasMore = true;
        _nextStart = 0;
        _filteredResultCount = null;
        _sidebarOnDeckEntries = const [];
        _isLoadingOnDeck = false;
        _onDeckMessage = null;
        _onDeckMessageIsError = false;
        _categories = const [];
        _categoriesCacheKey = null;
        _selectedCategoryId = null;
        _selectedArchive = null;
        _selectedArchiveCategories = const [];
        _isLoadingSelectedArchiveCategories = false;
        _isUpdatingSelectedArchiveCategories = false;
        _isUpdatingSelectedArchiveRating = false;
        _selectedArchiveCategoryMessage = null;
        _selectedArchiveCategoryMessageIsError = false;
        _isRefreshRevalidating = false;
        _isBackgroundLibraryRefreshActive = false;
      });
    }
  }

  void _maybeRunInitialLibraryLoad() {
    final settings = SettingsModel.instance;
    if (_didRunInitialLibraryLoad || !settings.isLoaded) {
      return;
    }

    if (!_didApplyPersistedLibraryFilters) {
      _applyPersistedLibraryFilters(settings);
    }

    _didRunInitialLibraryLoad = true;
    if (!settings.isValid) {
      return;
    }

    _settingsConnectionKey = '${settings.serverUrl}|${settings.apiKey}';
    _loadCategories();
    _refreshOnDeck();
    _reloadLibrary();
  }

  void _applyPersistedLibraryFilters(SettingsModel settings) {
    _didApplyPersistedLibraryFilters = true;

    final storedCategoryId = settings.librarySelectedCategoryId.trim();
    final storedSortId = settings.librarySortId.trim();
    final storedSortOrder = settings.librarySortOrder.trim().toLowerCase();

    setState(() {
      _selectedCategoryId = storedCategoryId.isEmpty ? null : storedCategoryId;
      _selectedSort = LibrarySortOption.fromId(
        storedSortId.isEmpty ? LibrarySortOption.title.id : storedSortId,
      );
      _sortOrder = storedSortOrder == 'desc' ? 'desc' : 'asc';
      _newOnly = settings.libraryNewOnly;
      _untaggedOnly = settings.libraryUntaggedOnly;
      _hideCompleted = settings.libraryHideCompleted;
    });
  }

  void _persistLibraryFilters() {
    unawaited(
      SettingsModel.instance.updateLibraryPreferences(
        selectedCategoryId: _selectedCategoryId ?? '',
        sortId: _selectedSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untaggedOnly: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );
  }

  void _resetLibraryFilters() {
    if (_isAtDefaultLibraryState) {
      return;
    }

    _controller.clear();

    setState(() {
      _selectedCategoryId = null;
      _selectedSort = LibrarySortOption.title;
      _sortOrder = 'asc';
      _newOnly = false;
      _untaggedOnly = false;
      _hideCompleted = false;
      _libraryHistory.clear();
      _suggestions = const [];
      _highlightedSuggestionIndex = -1;
    });

    unawaited(SettingsModel.instance.clearLibraryPreferences());
    _reloadLibrary(query: '');
  }

  @override
  void dispose() {
    if (desktopWindowControlsEnabled) {
      windowManager.removeListener(this);
    }
    _focusRevalidateTimer?.cancel();
    _libraryRefreshSubscription.close();
    ref.read(libraryStateProvider).removeListener(_handleLibraryStateChanged);
    SettingsModel.instance.removeListener(_onSettingsChanged);
    _controller.removeListener(_onQueryChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (mounted) {
      setState(() {});
    }
    _updateSuggestions();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _isInitialLoading ||
        _isLoadingMore ||
        !_hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.extentAfter < 800) {
      _loadMore();
    }
  }

  void _loadLibrary() {
    _reloadLibrary();
  }

  Future<void> _revalidateLibraryOnFocus() async {
    if (!mounted || !SettingsModel.instance.isValid) {
      return;
    }

    final now = DateTime.now();
    final lastSuccessfulFocusRevalidationAt =
        _lastSuccessfulFocusRevalidationAt;
    if (lastSuccessfulFocusRevalidationAt != null &&
        now.difference(lastSuccessfulFocusRevalidationAt) <
            _focusRevalidateCooldown) {
      return;
    }

    final cachedArchiveCount = _libraryState.lastKnownArchiveCount;
    if (cachedArchiveCount == null) {
      return;
    }

    final client = LanraragiClient(
      SettingsModel.instance.serverUrl,
      SettingsModel.instance.apiKey,
    );

    int? remoteArchiveCount;
    try {
      remoteArchiveCount = await client.getArchiveCount();
    } catch (_) {
      return;
    }

    _lastSuccessfulFocusRevalidationAt = now;

    if (!mounted ||
        remoteArchiveCount == null ||
        remoteArchiveCount == cachedArchiveCount) {
      return;
    }

    await _refreshLibraryInBackground(
      showIndicator: false,
      showErrorToast: true,
    );
  }

  Future<void> _refreshVisibleDataInBackground() async {
    await Future.wait<void>([
      _refreshLibraryInBackground(showIndicator: true, showErrorToast: true),
      _refreshOnDeck(),
    ]);
  }

  Future<void> _refreshLibraryInBackground({
    required bool showIndicator,
    required bool showErrorToast,
  }) async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || _isBackgroundLibraryRefreshActive) {
      return;
    }

    final currentlyLoadedItemCount = _items.length;
    setState(() {
      _isBackgroundLibraryRefreshActive = true;
      if (showIndicator) {
        _isRefreshRevalidating = true;
      }
    });

    final client = LanraragiClient(settings.serverUrl, settings.apiKey);

    try {
      final snapshot = await _fetchLibrarySnapshot(
        client: client,
        minimumItemCount: currentlyLoadedItemCount,
      );
      if (!mounted) {
        return;
      }

      imageCache.clear();

      setState(() {
        _items = snapshot.items;
        _nextStart = snapshot.nextStart;
        _hasMore = snapshot.hasMore;
        _filteredResultCount = snapshot.recordsFiltered ?? _filteredResultCount;
        _loadError = null;
        _loadMoreError = null;
      });
      _libraryState.setItems(
        snapshot.items,
        archiveCount: snapshot.archiveCount,
      );
      _prefetchThumbnails(snapshot.items);
      _updateSuggestions();
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (showErrorToast) {
        _showStatusSnackBar(
          error.toString().replaceFirst('LanraragiException: ', ''),
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBackgroundLibraryRefreshActive = false;
          _isRefreshRevalidating = false;
        });
      }
    }
  }

  Future<_LibraryRefreshSnapshot> _fetchLibrarySnapshot({
    required LanraragiClient client,
    required int minimumItemCount,
  }) async {
    final items = <Archive>[];
    final seenIds = <String>{};
    var start = 0;
    int? recordsFiltered;
    int? archiveCount;
    var hasMore = true;
    final targetCount = minimumItemCount <= 0 ? 1 : minimumItemCount;

    while (hasMore && (items.length < targetCount || start == 0)) {
      final page = await client.fetchArchivePage(
        filter: _activeQuery,
        start: start,
        options: _searchOptions,
      );

      archiveCount ??= page.recordsTotal ?? page.recordsFiltered;
      recordsFiltered = page.recordsFiltered ?? recordsFiltered;
      start = page.nextStart;
      hasMore = page.hasMore;

      for (final archive in page.items) {
        final archiveId = archive.id;
        if (archiveId.isNotEmpty && !seenIds.add(archiveId)) {
          continue;
        }
        items.add(archive);
      }

      if (page.items.isEmpty) {
        break;
      }
    }

    return _LibraryRefreshSnapshot(
      items: List.unmodifiable(items),
      nextStart: start,
      hasMore: hasMore,
      recordsFiltered: recordsFiltered,
      archiveCount: archiveCount,
    );
  }

  void _search(String q) {
    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: q,
        selectedCategoryId: _selectedCategoryId,
        sortField: _selectedSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );
    _reloadLibrary(query: q);
  }

  KeyEventResult _handleSearchKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || _suggestions.isEmpty) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSuggestionSelection(1);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSuggestionSelection(-1);
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final highlightedSuggestion = _highlightedSuggestion;
      if (highlightedSuggestion != null) {
        _applySuggestion(highlightedSuggestion);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_suggestions.isNotEmpty || _highlightedSuggestionIndex != -1) {
        setState(() {
          _suggestions = const [];
          _highlightedSuggestionIndex = -1;
        });
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _moveSuggestionSelection(int offset) {
    if (_suggestions.isEmpty) {
      return;
    }

    setState(() {
      if (_highlightedSuggestionIndex == -1) {
        _highlightedSuggestionIndex = offset > 0 ? 0 : _suggestions.length - 1;
      } else {
        _highlightedSuggestionIndex =
            (_highlightedSuggestionIndex + offset) % _suggestions.length;
        if (_highlightedSuggestionIndex < 0) {
          _highlightedSuggestionIndex += _suggestions.length;
        }
      }
    });
  }

  _SearchSuggestion? get _highlightedSuggestion {
    if (_highlightedSuggestionIndex < 0 ||
        _highlightedSuggestionIndex >= _suggestions.length) {
      return null;
    }
    return _suggestions[_highlightedSuggestionIndex];
  }

  void _handleSearchSubmitted(String query) {
    final highlightedSuggestion = _highlightedSuggestion;
    if (highlightedSuggestion != null) {
      _applySuggestion(highlightedSuggestion);
      return;
    }
    _search(query);
  }

  void _openArchiveDetails(Archive archive) {
    setState(() {
      _selectedArchive = archive;
      _selectedArchiveCategories = const [];
      _isLoadingSelectedArchiveCategories = true;
      _isUpdatingSelectedArchiveCategories = false;
      _isUpdatingSelectedArchiveRating = false;
      _isDeletingSelectedArchive = false;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });
    _loadSelectedArchiveCategories(archive.id);
  }

  void _closeArchiveDetails() {
    if (!_isDetailsOpen) {
      return;
    }
    setState(() {
      _selectedArchive = null;
      _selectedArchiveCategories = const [];
      _isLoadingSelectedArchiveCategories = false;
      _isUpdatingSelectedArchiveCategories = false;
      _isUpdatingSelectedArchiveRating = false;
      _isDeletingSelectedArchive = false;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });
  }

  bool _isArchiveRatingTag(String tag) {
    return tag.trim().toLowerCase().startsWith(_archiveRatingPrefix);
  }

  int? _archiveRatingFromTags(Iterable<String> tags) {
    for (final rawTag in tags) {
      final normalizedTag = rawTag.trim();
      if (!_isArchiveRatingTag(normalizedTag)) {
        continue;
      }
      final stars = '⭐'.allMatches(normalizedTag).length;
      if (stars >= 1 && stars <= 5) {
        return stars;
      }
    }
    return null;
  }

  Future<void> _updateSelectedArchiveRating(int tappedRating) async {
    final archive = _selectedArchive;
    final settings = SettingsModel.instance;
    if (archive == null ||
        archive.id.trim().isEmpty ||
        !settings.isValid ||
        _isUpdatingSelectedArchiveRating) {
      return;
    }

    final currentRating = _archiveRatingFromTags(archive.parsedTags);
    final nextRating = currentRating == tappedRating ? null : tappedRating;
    final nextTags = archive.parsedTags
        .where((tag) => !_isArchiveRatingTag(tag))
        .toList(growable: true);
    if (nextRating != null) {
      nextTags.add('rating:${'⭐' * nextRating}');
    }
    final nextTagString = nextTags.join(', ');

    setState(() {
      _isUpdatingSelectedArchiveRating = true;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });

    try {
      await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).updateArchiveMetadata(archive.id, tags: nextTagString);
      if (!mounted || _selectedArchive?.id != archive.id) {
        return;
      }

      final updatedArchive = archive.copyWith(tags: nextTagString);
      final nextItems = _items
          .map((entry) => entry.id == archive.id ? updatedArchive : entry)
          .toList(growable: false);

      setState(() {
        _selectedArchive = updatedArchive;
        _items = nextItems;
      });
      _libraryState.setItems(
        nextItems,
        archiveCount: _libraryState.lastKnownArchiveCount,
      );
    } catch (error) {
      if (!mounted || _selectedArchive?.id != archive.id) {
        return;
      }
      setState(() {
        _selectedArchiveCategoryMessage = error.toString().replaceFirst(
          'LanraragiException: ',
          '',
        );
        _selectedArchiveCategoryMessageIsError = true;
      });
    } finally {
      if (mounted && _selectedArchive?.id == archive.id) {
        setState(() {
          _isUpdatingSelectedArchiveRating = false;
        });
      }
    }
  }

  void _readSelectedArchive() {
    final archive = _selectedArchive;
    if (archive == null) {
      return;
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ReaderScreen(archive: archive)))
        .then((_) => _refreshOnDeck());
  }

  Future<void> _reloadLibrary({String? query}) async {
    _ensureTagStatsLoaded();
    final trimmedQuery = (query ?? _controller.text).trim();
    final generation = ++_reloadGeneration;
    setState(() {
      _items = const [];
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMore = true;
      _nextStart = 0;
      _filteredResultCount = null;
      _activeQuery = trimmedQuery;
      _loadError = null;
      _loadMoreError = null;
    });
    ref.read(libraryStateProvider).clearItems();
    await _loadMore(generation: generation, fromReload: true);
  }

  Future<void> _loadMore({int? generation, bool fromReload = false}) async {
    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }
    final currentGeneration = generation ?? _reloadGeneration;
    if (currentGeneration != _reloadGeneration) {
      return;
    }
    if (!fromReload && (_isInitialLoading || _isLoadingMore || !_hasMore)) {
      return;
    }

    if (!fromReload) {
      setState(() {
        _isLoadingMore = true;
        _loadMoreError = null;
      });
    }

    final client = LanraragiClient(settings.serverUrl, settings.apiKey);
    try {
      final page = await client.fetchArchivePage(
        filter: _activeQuery,
        start: _nextStart,
        options: _searchOptions,
      );
      if (!mounted || currentGeneration != _reloadGeneration) {
        return;
      }

      final seenIds = _items
          .map((archive) => archive.id)
          .where((id) => id.isNotEmpty)
          .toSet();
      final newItems = page.items
          .where((archive) {
            if (archive.id.isEmpty) {
              return true;
            }
            return !seenIds.contains(archive.id);
          })
          .toList(growable: false);

      setState(() {
        _items = fromReload ? newItems : [..._items, ...newItems];
        _nextStart = page.nextStart;
        _hasMore = page.hasMore;
        _filteredResultCount = page.recordsFiltered ?? _filteredResultCount;
        _isInitialLoading = false;
        _isLoadingMore = false;
        _loadError = null;
        _loadMoreError = null;
      });
      _libraryState.setItems(
        _items,
        archiveCount: page.recordsTotal ?? page.recordsFiltered,
      );
      _prefetchThumbnails(newItems);
      _updateSuggestions();
    } catch (error) {
      if (!mounted || currentGeneration != _reloadGeneration) {
        return;
      }
      setState(() {
        if (fromReload) {
          _isInitialLoading = false;
          _loadError = error;
          _hasMore = false;
        } else {
          _isLoadingMore = false;
          _loadMoreError = error;
        }
      });
    }
  }

  ArchiveSearchOptions get _searchOptions {
    return ArchiveSearchOptions(
      categoryId: _selectedCategoryId,
      sortBy: _selectedSort.apiValue,
      order: _sortOrder,
      newOnly: _newOnly,
      untaggedOnly: _untaggedOnly,
      hideCompleted: _hideCompleted,
    );
  }

  Future<void> _loadCategories({bool force = false}) async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || _isLoadingCategories) {
      return;
    }

    final cacheKey =
        '${settings.serverUrl}|${LanraragiClient.normalizeApiKey(settings.apiKey)}';
    if (!force && _categoriesCacheKey == cacheKey && _categories.isNotEmpty) {
      return;
    }

    _isLoadingCategories = true;
    final client = LanraragiClient(settings.serverUrl, settings.apiKey);
    try {
      final categories = await client.getCategories();
      if (!mounted) {
        return;
      }

      final selectedExists =
          _selectedCategoryId == null ||
          categories.any((category) => category.id == _selectedCategoryId);
      setState(() {
        _categories = categories;
        _categoriesCacheKey = cacheKey;
        if (!selectedExists) {
          _selectedCategoryId = null;
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _categories = const [];
        _categoriesCacheKey = null;
        _selectedCategoryId = null;
      });
    } finally {
      _isLoadingCategories = false;
    }
  }

  void _showStatusSnackBar(String message, {required bool isError}) {
    if (!mounted || message.trim().isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final mediaQuery = MediaQuery.of(context);
    final rightMargin = 20.0 + mediaQuery.padding.right;
    final bottomMargin = 20.0 + mediaQuery.padding.bottom;
    final availableWidth = mediaQuery.size.width - rightMargin - 16;
    final toastWidth = availableWidth > 280 ? 280.0 : availableWidth;
    final computedLeftMargin = mediaQuery.size.width - toastWidth - rightMargin;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          dismissDirection: DismissDirection.down,
          duration: const Duration(seconds: 2),
          elevation: 0,
          margin: EdgeInsets.only(
            left: computedLeftMargin < 16 ? 16 : computedLeftMargin,
            right: rightMargin,
            bottom: bottomMargin,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          backgroundColor: const Color(0xFF1A1A1A),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          content: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
  }

  Future<void> _deleteSelectedArchive() async {
    final archive = _selectedArchive;
    final settings = SettingsModel.instance;
    if (archive == null || archive.id.trim().isEmpty || !settings.isValid) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteArchiveDialog(archiveTitle: archive.title),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _isDeletingSelectedArchive = true;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });

    final archiveId = archive.id;
    final client = LanraragiClient(settings.serverUrl, settings.apiKey);

    try {
      await client.deleteArchive(archiveId);
      if (!mounted) {
        return;
      }

      final nextItems = _items
          .where((entry) => entry.id != archiveId)
          .toList(growable: false);
      final nextOnDeckEntries = _sidebarOnDeckEntries
          .where((entry) => entry.archiveId != archiveId)
          .toList(growable: false);
      final nextFilteredResultCount = _filteredResultCount == null
          ? null
          : (_filteredResultCount! > 0 ? _filteredResultCount! - 1 : 0);
      final nextArchiveCount = _libraryState.lastKnownArchiveCount == null
          ? null
          : (_libraryState.lastKnownArchiveCount! > 0
                ? _libraryState.lastKnownArchiveCount! - 1
                : 0);

      setState(() {
        _items = nextItems;
        _sidebarOnDeckEntries = nextOnDeckEntries;
        _filteredResultCount = nextFilteredResultCount;
      });
      _libraryState.setItems(nextItems, archiveCount: nextArchiveCount);
      _libraryState.setOnDeckEntries(nextOnDeckEntries);
      await SettingsModel.instance.removeOnDeckEntry(archiveId);
      _closeArchiveDetails();
      _showStatusSnackBar('Archive deleted.', isError: false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isDeletingSelectedArchive = false;
        _selectedArchiveCategoryMessage = error.toString().replaceFirst(
          'LanraragiException: ',
          '',
        );
        _selectedArchiveCategoryMessageIsError = true;
      });
    }
  }

  Future<void> _reloadSelectedArchiveCategoriesIfNeeded() async {
    final archiveId = _selectedArchive?.id;
    if (!mounted || archiveId == null || archiveId.isEmpty) {
      return;
    }
    setState(() {
      _isLoadingSelectedArchiveCategories = true;
    });
    await _loadSelectedArchiveCategories(archiveId);
  }

  Future<void> _showCreateCategoryDialog() async {
    final previousCategoryIds = _categories
        .map((category) => category.id)
        .toSet();
    final result = await showDialog<_CategoryDialogResult>(
      context: context,
      builder: (context) => const _CategoryDialog(
        title: AppStrings.createCategory,
        submitLabel: AppStrings.create,
      ),
    );
    if (result == null) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    try {
      final client = LanraragiClient(settings.serverUrl, settings.apiKey);
      await client.createCategory(
        name: result.name,
        search: result.search,
        pinned: result.pinned,
      );
      await _loadCategories(force: true);
      if (!mounted) {
        return;
      }
      final createdCategory =
          _categories
              .where((category) => !previousCategoryIds.contains(category.id))
              .firstOrNull ??
          _categories
              .where(
                (category) =>
                    category.name == result.name &&
                    category.search == result.search &&
                    category.pinned == result.pinned,
              )
              .firstOrNull;
      if (createdCategory != null && createdCategory.id.isNotEmpty) {
        _updateCategory(createdCategory.id);
      }
      _showStatusSnackBar(AppStrings.categoryCreated, isError: false);
    } catch (error) {
      _showStatusSnackBar(
        error.toString().replaceFirst('LanraragiException: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _showEditCategoryDialog(LanraragiCategory category) async {
    final result = await showDialog<_CategoryDialogResult>(
      context: context,
      builder: (context) => _CategoryDialog(
        title: AppStrings.editCategory,
        submitLabel: AppStrings.save,
        initialName: category.name,
        initialSearch: category.search,
        initialPinned: category.pinned,
      ),
    );
    if (result == null) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    try {
      final client = LanraragiClient(settings.serverUrl, settings.apiKey);
      await client.updateCategory(
        categoryId: category.id,
        name: result.name,
        search: result.search,
        pinned: result.pinned,
      );
      await _loadCategories(force: true);
      await _reloadSelectedArchiveCategoriesIfNeeded();
      if (!mounted) {
        return;
      }
      _showStatusSnackBar(AppStrings.categoryUpdated, isError: false);
    } catch (error) {
      _showStatusSnackBar(
        error.toString().replaceFirst('LanraragiException: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _showDeleteCategoryDialog(LanraragiCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteCategoryDialog(categoryName: category.name),
    );
    if (confirmed != true) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    try {
      final client = LanraragiClient(settings.serverUrl, settings.apiKey);
      await client.deleteCategory(category.id);
      if (!mounted) {
        return;
      }
      final wasSelected = _selectedCategoryId == category.id;
      setState(() {
        _categories = _categories
            .where((entry) => entry.id != category.id)
            .toList(growable: false);
        _selectedArchiveCategories = _selectedArchiveCategories
            .where((entry) => entry.id != category.id)
            .toList(growable: false);
        if (wasSelected) {
          _selectedCategoryId = null;
        }
      });
      if (wasSelected) {
        _reloadLibrary();
      }
      _showStatusSnackBar(AppStrings.categoryDeleted, isError: false);
    } catch (error) {
      _showStatusSnackBar(
        error.toString().replaceFirst('LanraragiException: ', ''),
        isError: true,
      );
    }
  }

  Future<void> _loadSelectedArchiveCategories(String archiveId) async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || archiveId.isEmpty) {
      return;
    }

    try {
      final categories = await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).getArchiveCategories(archiveId);
      if (!mounted || _selectedArchive?.id != archiveId) {
        return;
      }
      setState(() {
        _selectedArchiveCategories = categories;
        _isLoadingSelectedArchiveCategories = false;
        _selectedArchiveCategoryMessage = null;
        _selectedArchiveCategoryMessageIsError = false;
      });
    } catch (error) {
      if (!mounted || _selectedArchive?.id != archiveId) {
        return;
      }
      setState(() {
        _selectedArchiveCategories = const [];
        _isLoadingSelectedArchiveCategories = false;
        _selectedArchiveCategoryMessage = error.toString().replaceFirst(
          'LanraragiException: ',
          '',
        );
        _selectedArchiveCategoryMessageIsError = true;
      });
    }
  }

  Future<void> _addSelectedArchiveToCategory(String categoryId) async {
    final archive = _selectedArchive;
    if (archive == null ||
        categoryId.isEmpty ||
        _isUpdatingSelectedArchiveCategories) {
      return;
    }

    final category = _categories
        .where((entry) => entry.id == categoryId)
        .firstOrNull;
    if (category == null || category.isDynamic) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    setState(() {
      _isUpdatingSelectedArchiveCategories = true;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });
    final libraryState = ref.read(libraryStateProvider);
    libraryState.clearItems();
    libraryState.clearOnDeckEntries();

    try {
      await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).addArchiveToCategory(categoryId, archive.id);
      await _loadSelectedArchiveCategories(archive.id);
      if (mounted) {
        ref.invalidate(libraryProvider);
      }
    } catch (error) {
      if (mounted && _selectedArchive?.id == archive.id) {
        setState(() {
          _selectedArchiveCategoryMessage = error.toString().replaceFirst(
            'LanraragiException: ',
            '',
          );
          _selectedArchiveCategoryMessageIsError = true;
        });
      }
    } finally {
      if (mounted && _selectedArchive?.id == archive.id) {
        setState(() {
          _isUpdatingSelectedArchiveCategories = false;
        });
      }
    }
  }

  Future<void> _removeSelectedArchiveFromCategory(String categoryId) async {
    final archive = _selectedArchive;
    if (archive == null ||
        categoryId.isEmpty ||
        _isUpdatingSelectedArchiveCategories) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    setState(() {
      _isUpdatingSelectedArchiveCategories = true;
      _selectedArchiveCategoryMessage = null;
      _selectedArchiveCategoryMessageIsError = false;
    });

    try {
      await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).removeArchiveFromCategory(categoryId, archive.id);
      await _loadSelectedArchiveCategories(archive.id);
      if (mounted) {
        ref.invalidate(libraryProvider);
      }
    } catch (error) {
      if (mounted && _selectedArchive?.id == archive.id) {
        setState(() {
          _selectedArchiveCategoryMessage = error.toString().replaceFirst(
            'LanraragiException: ',
            '',
          );
          _selectedArchiveCategoryMessageIsError = true;
        });
      }
    } finally {
      if (mounted && _selectedArchive?.id == archive.id) {
        setState(() {
          _isUpdatingSelectedArchiveCategories = false;
        });
      }
    }
  }

  void _prefetchThumbnails(List<Archive> archives) {
    if (!desktopWindowControlsEnabled || archives.isEmpty || !mounted) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    final candidates = archives
        .where((archive) => archive.id.isNotEmpty)
        .take(6)
        .toList(growable: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      for (final archive in candidates) {
        final thumbnailUrl = archive.thumbnailUrl(settings.serverUrl);
        if (thumbnailUrl == null) {
          continue;
        }
        final provider = NetworkImage(
          thumbnailUrl,
          headers: settings.authHeader(),
        );
        precacheImage(provider, context);
      }
    });
  }

  Archive? _findLoadedArchive(String archiveId) {
    for (final archive in _items) {
      if (archive.id == archiveId) {
        return archive;
      }
    }

    final selectedArchive = _selectedArchive;
    if (selectedArchive != null && selectedArchive.id == archiveId) {
      return selectedArchive;
    }

    return null;
  }

  Future<void> _openOnDeckEntry(OnDeckEntry entry) async {
    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    try {
      final archive =
          _findLoadedArchive(entry.archiveId) ??
          await LanraragiClient(
            settings.serverUrl,
            settings.apiKey,
          ).getArchive(entry.archiveId);
      if (!mounted) {
        return;
      }

      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => ReaderScreen(
                archive: archive,
                initialPage: entry.currentPage,
              ),
            ),
          )
          .then((_) => _refreshOnDeck());
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.toString().replaceFirst('LanraragiException: ', ''),
          ),
        ),
      );
    }
  }

  void _applyLocalOnDeckFallback() {
    final entries = SettingsModel.instance.onDeckEntries.toList(
      growable: false,
    );
    setState(() {
      _sidebarOnDeckEntries = entries;
      _isLoadingOnDeck = false;
      _onDeckMessage = entries.isEmpty
          ? AppStrings.noRecentInProgressArchives
          : null;
      _onDeckMessageIsError = false;
    });
    ref.read(libraryStateProvider).setOnDeckEntries(entries);
  }

  Future<void> _refreshOnDeck() async {
    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    if (settings.useLocalOnDeckFallback) {
      _applyLocalOnDeckFallback();
      return;
    }

    setState(() {
      _isLoadingOnDeck = true;
      _onDeckMessage = null;
      _onDeckMessageIsError = false;
    });

    try {
      final archives = await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).getOnDeckArchives();
      if (!mounted) {
        return;
      }

      final entries = archives
          .where(
            (archive) =>
                archive.id.isNotEmpty && archive.title.trim().isNotEmpty,
          )
          .map(OnDeckEntry.fromArchive)
          .toList(growable: false);

      setState(() {
        _sidebarOnDeckEntries = entries;
        _isLoadingOnDeck = false;
        _onDeckMessage = entries.isEmpty
            ? AppStrings.noRecentInProgressArchives
            : null;
        _onDeckMessageIsError = false;
      });
      ref.read(libraryStateProvider).setOnDeckEntries(entries);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _sidebarOnDeckEntries = const <OnDeckEntry>[];
        _isLoadingOnDeck = false;
        _onDeckMessage = error.toString().replaceFirst(
          'LanraragiException: ',
          '',
        );
        _onDeckMessageIsError = true;
      });
      ref.read(libraryStateProvider).clearOnDeckEntries();
    }
  }

  void _setRandomPickMessage(String message, {required bool isError}) {
    setState(() {
      _randomPickMessage = message;
      _randomPickMessageIsError = isError;
    });
  }

  Future<void> _pickRandomArchive() async {
    if (_isPickingRandom) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      _setRandomPickMessage(AppStrings.configureServerFirst, isError: true);
      return;
    }

    setState(() {
      _isPickingRandom = true;
      _randomPickMessage = null;
      _randomPickMessageIsError = false;
    });

    try {
      final pickedArchive = await LanraragiClient(
        settings.serverUrl,
        settings.apiKey,
      ).getRandomArchive();

      if (!mounted) {
        return;
      }

      if (pickedArchive == null) {
        _setRandomPickMessage(
          AppStrings.noMatchingRandomArchive,
          isError: false,
        );
        return;
      }

      setState(() {
        _selectedArchive = pickedArchive;
        _selectedArchiveCategories = const [];
        _isLoadingSelectedArchiveCategories = true;
        _selectedArchiveCategoryMessage = null;
        _selectedArchiveCategoryMessageIsError = false;
        _randomPickMessage = null;
        _randomPickMessageIsError = false;
      });
      _loadSelectedArchiveCategories(pickedArchive.id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setRandomPickMessage(
        error.toString().replaceFirst('LanraragiException: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPickingRandom = false;
        });
      }
    }
  }

  Future<void> _ensureTagStatsLoaded() async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || _isLoadingTagStats) {
      return;
    }

    final cacheKey =
        '${settings.serverUrl}|${LanraragiClient.normalizeApiKey(settings.apiKey)}';
    if (_tagStatsCacheKey == cacheKey && _tagStats.isNotEmpty) {
      return;
    }

    _isLoadingTagStats = true;
    final client = LanraragiClient(settings.serverUrl, settings.apiKey);
    try {
      final stats = await client.getTagStats();
      if (!mounted) {
        return;
      }
      setState(() {
        _tagStats = stats;
        _tagStatsCacheKey = cacheKey;
      });
      _updateSuggestions();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _tagStats = const [];
      });
    } finally {
      _isLoadingTagStats = false;
    }
  }

  void _updateSuggestions() {
    final activeToken = _activeToken();
    if (!_focusNode.hasFocus || activeToken.isEmpty) {
      if ((_suggestions.isNotEmpty || _highlightedSuggestionIndex != -1) &&
          mounted) {
        setState(() {
          _suggestions = const [];
          _highlightedSuggestionIndex = -1;
        });
      }
      return;
    }

    final nextSuggestions = _buildSuggestions(activeToken, _controller.text);
    if (!_sameSuggestions(_suggestions, nextSuggestions) && mounted) {
      setState(() {
        _suggestions = nextSuggestions;
        if (nextSuggestions.isEmpty) {
          _highlightedSuggestionIndex = -1;
        } else if (_highlightedSuggestionIndex >= nextSuggestions.length) {
          _highlightedSuggestionIndex = nextSuggestions.length - 1;
        }
      });
    }
  }

  List<_SearchSuggestion> _buildSuggestions(String token, String fullQuery) {
    final lowerToken = token.toLowerCase();
    final entries = <String, _SearchSuggestion>{};

    for (final stat in _tagStats) {
      if (stat.value.toLowerCase().contains(lowerToken)) {
        final suggestion = _SearchSuggestion.fromTagStat(stat);
        entries.putIfAbsent(suggestion.label.toLowerCase(), () => suggestion);
      }
    }

    for (final archive in _items) {
      for (final term in _titleTerms(archive.title)) {
        if (term.contains(lowerToken)) {
          final suggestion = _SearchSuggestion(
            label: term,
            filterValue: term,
            kind: 'title',
            weight: 0,
            priority: 1,
          );
          entries.putIfAbsent(suggestion.label.toLowerCase(), () => suggestion);
        }
      }
    }

    final suggestions = entries.values.toList()
      ..sort((a, b) {
        final sourceCompare = a.priority.compareTo(b.priority);
        if (sourceCompare != 0) {
          return sourceCompare;
        }
        final aStarts = a.label.toLowerCase().startsWith(lowerToken) ? 0 : 1;
        final bStarts = b.label.toLowerCase().startsWith(lowerToken) ? 0 : 1;
        final kindCompare = aStarts.compareTo(bStarts);
        if (kindCompare != 0) {
          return kindCompare;
        }
        final weightCompare = b.weight.compareTo(a.weight);
        if (weightCompare != 0) {
          return weightCompare;
        }
        return a.label.compareTo(b.label);
      });

    return suggestions.take(10).toList(growable: false);
  }

  Iterable<String> _titleTerms(String title) {
    final pattern = RegExp(r"[A-Za-z0-9][A-Za-z0-9'\-]{2,}");
    return pattern
        .allMatches(title)
        .map((match) => match.group(0)!.toLowerCase())
        .toSet();
  }

  String _activeToken() {
    final query = _controller.text;
    if (query.isEmpty) {
      return '';
    }
    final range = _activeTokenRange(query);
    if (range.isCollapsed) {
      return '';
    }
    return query
        .substring(range.start, range.end)
        .replaceAll('"', '')
        .replaceAll(r'$', '')
        .trim();
  }

  void _applySuggestion(_SearchSuggestion suggestion) {
    final currentText = _controller.text;
    final range = _activeTokenRange(currentText);
    final replacement = suggestion.filterValue + r'$, ';
    final prefix = currentText.substring(0, range.start);
    final suffix = currentText
        .substring(range.end)
        .replaceFirst(RegExp(r'^[\s,-]+'), '');
    final nextText = '$prefix$replacement$suffix';

    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: prefix.length + replacement.length,
      ),
    );

    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: nextText,
        selectedCategoryId: _selectedCategoryId,
        sortField: _selectedSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );

    setState(() {
      _suggestions = const [];
      _highlightedSuggestionIndex = -1;
    });
    _focusNode.requestFocus();
    _reloadLibrary(query: nextText);
  }

  void _applyTagFilter(String tag) {
    final formattedTag = _formatExactTagFilter(tag);

    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: formattedTag,
        selectedCategoryId: _selectedCategoryId,
        sortField: _selectedSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );

    _controller.value = TextEditingValue(
      text: formattedTag,
      selection: TextSelection.collapsed(offset: formattedTag.length),
    );

    setState(() {
      _suggestions = const [];
      _selectedArchive = null;
      _highlightedSuggestionIndex = -1;
    });

    _reloadLibrary(query: formattedTag);
  }

  String _formatExactTagFilter(String tag) {
    var normalized = tag.trim();
    if (normalized.isEmpty) {
      return normalized;
    }

    final hasExactSuffix = normalized.endsWith(r'$');
    if (hasExactSuffix) {
      normalized = normalized.substring(0, normalized.length - 1).trimRight();
    }

    return hasExactSuffix ? normalized + r'$' : normalized + r'$';
  }

  TextRange _activeTokenRange(String text) {
    final selection = _controller.selection;
    final rawCursor = selection.isValid ? selection.extentOffset : text.length;
    final cursor = rawCursor.clamp(0, text.length);

    var start = cursor;
    while (start > 0 && !_isTokenBoundary(text[start - 1])) {
      start -= 1;
    }

    var end = cursor;
    while (end < text.length && !_isTokenBoundary(text[end])) {
      end += 1;
    }

    return TextRange(start: start, end: end);
  }

  bool _isTokenBoundary(String character) {
    return character == ',' ||
        character == '-' ||
        RegExp(r'\s').hasMatch(character);
  }

  bool _sameSuggestions(List<_SearchSuggestion> a, List<_SearchSuggestion> b) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].label != b[i].label || a[i].kind != b[i].kind) {
        return false;
      }
    }
    return true;
  }

  void _updateSortBy(String? value) {
    if (value == null) {
      return;
    }
    final nextSort = LibrarySortOption.fromId(value);
    if (nextSort.id == _selectedSort.id) {
      return;
    }

    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: _activeQuery,
        selectedCategoryId: _selectedCategoryId,
        sortField: nextSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );

    setState(() {
      _selectedSort = nextSort;
    });
    _persistLibraryFilters();
    _reloadLibrary();
  }

  void _toggleSortOrder() {
    final nextSortOrder = _sortOrder == 'asc' ? 'desc' : 'asc';

    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: _activeQuery,
        selectedCategoryId: _selectedCategoryId,
        sortField: _selectedSort.id,
        sortOrder: nextSortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );

    setState(() {
      _sortOrder = nextSortOrder;
    });
    _persistLibraryFilters();
    _reloadLibrary();
  }

  void _updateCategory(String? value) {
    final nextValue = value == null || value.isEmpty ? null : value;
    if (nextValue == _selectedCategoryId) {
      return;
    }

    _pushLibraryHistoryIfNeeded(
      _LibraryHistoryEntry(
        searchQuery: _activeQuery,
        selectedCategoryId: nextValue,
        sortField: _selectedSort.id,
        sortOrder: _sortOrder,
        newOnly: _newOnly,
        untagged: _untaggedOnly,
        hideCompleted: _hideCompleted,
      ),
    );

    setState(() {
      _selectedCategoryId = nextValue;
    });
    _persistLibraryFilters();
    _reloadLibrary();
  }

  List<LanraragiCategory> get _staticCategories => _categories
      .where((category) => category.isStatic)
      .toList(growable: false);

  List<LanraragiCategory> get _dynamicCategories => _categories
      .where((category) => category.isDynamic)
      .toList(growable: false);

  void _toggleFlagFilter({
    required bool currentValue,
    required _LibraryHistoryEntry nextState,
    required VoidCallback apply,
  }) {
    _pushLibraryHistoryIfNeeded(nextState);
    apply();
    _persistLibraryFilters();
    _reloadLibrary();
  }

  List<_GroupedTagNamespace> _groupArchiveTags(Archive archive) {
    final grouped = <String, List<String>>{};
    for (final rawTag in archive.parsedTags) {
      if (_isArchiveRatingTag(rawTag)) {
        continue;
      }
      final separatorIndex = rawTag.indexOf(':');
      final namespace = separatorIndex == -1
          ? 'tag'
          : rawTag.substring(0, separatorIndex).trim();
      final normalizedNamespace = namespace.isEmpty ? 'tag' : namespace;
      if (normalizedNamespace.toLowerCase() == 'source') {
        continue;
      }
      grouped.putIfAbsent(normalizedNamespace, () => <String>[]).add(rawTag);
    }

    const preferredOrder = [
      'artist',
      'group',
      'series',
      'parody',
      'character',
      'language',
      'tag',
    ];
    final namespaces = grouped.keys.toList()
      ..sort((a, b) {
        final aIndex = preferredOrder.indexOf(a);
        final bIndex = preferredOrder.indexOf(b);
        if (aIndex != -1 || bIndex != -1) {
          if (aIndex == -1) return 1;
          if (bIndex == -1) return -1;
          return aIndex.compareTo(bIndex);
        }
        return a.compareTo(b);
      });

    return namespaces
        .map(
          (namespace) => _GroupedTagNamespace(
            namespace: namespace,
            tags: List.unmodifiable(grouped[namespace]!),
          ),
        )
        .toList(growable: false);
  }

  Widget _buildToolbar() {
    final namespaceOptionsById = <String, LibrarySortOption>{
      for (final option in LibrarySortOption.defaultNamespaceSortOptions)
        option.id: option,
    };
    for (final stat in _tagStats) {
      final separatorIndex = stat.value.indexOf(':');
      if (separatorIndex <= 0) {
        continue;
      }
      final namespace = stat.value.substring(0, separatorIndex).trim();
      if (namespace.isNotEmpty) {
        final option = LibrarySortOption.fromNamespace(namespace);
        namespaceOptionsById[option.id] = option;
      }
    }

    final namespaceOptions = namespaceOptionsById.values.toList()
      ..sort((a, b) {
        final aIndex = LibrarySortOption.defaultNamespaceSortOrder[a.id];
        final bIndex = LibrarySortOption.defaultNamespaceSortOrder[b.id];

        if (aIndex != null || bIndex != null) {
          if (aIndex == null) {
            return 1;
          }
          if (bIndex == null) {
            return -1;
          }
          return aIndex.compareTo(bIndex);
        }

        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    final compactFieldStyle = Theme.of(context).textTheme.bodyMedium;
    final sortOptions = [
      LibrarySortOption.title,
      ...namespaceOptions,
      LibrarySortOption.lastRead,
    ];

    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (_libraryHistory.isNotEmpty) ...[
              _LibraryHistoryBackButton(onPressed: _restorePreviousLibraryState),
              const SizedBox(width: 8),
            ],
            _ToolbarMenuButton<String>(
              width: 150,
              label: _selectedSort.label,
              items: sortOptions
                  .map(
                    (option) => _ToolbarMenuOption<String>(
                      value: option.id,
                      label: option.label,
                    ),
                  )
                  .toList(growable: false),
              onSelected: _updateSortBy,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _toggleSortOrder,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 0,
                ),
                side: const BorderSide(color: AppTheme.border, width: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                foregroundColor: AppTheme.textSecondary,
              ),
              icon: Icon(
                _sortOrder == 'asc' ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
              ),
              label: Text(
                _sortOrder == 'asc'
                    ? AppStrings.sortAscending
                    : AppStrings.sortDescending,
                style: compactFieldStyle,
              ),
            ),
            const SizedBox(width: 8),
            _CategoryFilterMenu(
              width: 190,
              label:
                  _categories
                      .where((category) => category.id == _selectedCategoryId)
                      .map((category) => category.name)
                      .cast<String?>()
                      .firstOrNull ??
                  AppStrings.allCategories,
              staticCategories: _staticCategories,
              dynamicCategories: _dynamicCategories,
              selectedCategoryId: _selectedCategoryId,
              onSelected: _updateCategory,
              onCreateCategory: _showCreateCategoryDialog,
              onEditCategory: _showEditCategoryDialog,
              onDeleteCategory: _showDeleteCategoryDialog,
            ),
            const SizedBox(width: 8),
            _FiltersMenuButton(
              newOnly: _newOnly,
              untaggedOnly: _untaggedOnly,
              hideCompleted: _hideCompleted,
              onToggleNewOnly: () => _toggleFlagFilter(
                currentValue: _newOnly,
                nextState: _LibraryHistoryEntry(
                  searchQuery: _activeQuery,
                  selectedCategoryId: _selectedCategoryId,
                  sortField: _selectedSort.id,
                  sortOrder: _sortOrder,
                  newOnly: !_newOnly,
                  untagged: !_newOnly ? false : _untaggedOnly,
                  hideCompleted: _hideCompleted,
                ),
                apply: () {
                  setState(() {
                    _newOnly = !_newOnly;
                    if (_newOnly) {
                      _untaggedOnly = false;
                    }
                  });
                },
              ),
              onToggleUntagged: () => _toggleFlagFilter(
                currentValue: _untaggedOnly,
                nextState: _LibraryHistoryEntry(
                  searchQuery: _activeQuery,
                  selectedCategoryId: _selectedCategoryId,
                  sortField: _selectedSort.id,
                  sortOrder: _sortOrder,
                  newOnly: !_untaggedOnly ? false : _newOnly,
                  untagged: !_untaggedOnly,
                  hideCompleted: _hideCompleted,
                ),
                apply: () {
                  setState(() {
                    _untaggedOnly = !_untaggedOnly;
                    if (_untaggedOnly) {
                      _newOnly = false;
                    }
                  });
                },
              ),
              onToggleHideCompleted: () => _toggleFlagFilter(
                currentValue: _hideCompleted,
                nextState: _LibraryHistoryEntry(
                  searchQuery: _activeQuery,
                  selectedCategoryId: _selectedCategoryId,
                  sortField: _selectedSort.id,
                  sortOrder: _sortOrder,
                  newOnly: _newOnly,
                  untagged: _untaggedOnly,
                  hideCompleted: !_hideCompleted,
                ),
                apply: () => setState(() => _hideCompleted = !_hideCompleted),
              ),
            ),
            if (!_isAtDefaultLibraryState) ...[
              const SizedBox(width: 8),
              _ResetFiltersButton(onPressed: _resetLibraryFilters),
            ],
          ],
        ),
      ),
    );
  }

  int _calculateGridColumns(double availableWidth) {
    const spacing = 8.0;
    const targetCardWidth = 168.0;
    const minCardWidth = 120.0;

    if (availableWidth <= minCardWidth) {
      return 1;
    }

    var columns = ((availableWidth + spacing) / (targetCardWidth + spacing))
        .floor()
        .clamp(1, 8);
    while (columns > 1) {
      final itemWidth = (availableWidth - (columns - 1) * spacing) / columns;
      if (itemWidth >= minCardWidth) {
        break;
      }
      columns -= 1;
    }
    return columns;
  }

  Widget _buildLibraryContent(BuildContext context, double availableWidth) {
    if (_isInitialLoading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null && _items.isEmpty) {
      return _LibraryLoadErrorView(
        message: _loadError.toString().replaceFirst('LanraragiException: ', ''),
        onRetry: _loadLibrary,
        onOpenSettings: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      );
    }

    if (_items.isEmpty) {
      return _LibraryEmptyView(onRefresh: _loadLibrary);
    }

    final columns = _calculateGridColumns(availableWidth);

    return Column(
      children: [
        Expanded(
          child: _Scrollbarless(
            child: GridView.builder(
              controller: _scrollController,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 2 / 3,
              ),
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final archive = _items[index];
                return CoverCard(
                  archive: archive,
                  onTap: () => _openArchiveDetails(archive),
                );
              },
            ),
          ),
        ),
        if (_isLoadingMore)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          )
        else if (_loadMoreError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    _loadMoreError.toString().replaceFirst(
                      'LanraragiException: ',
                      '',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _loadMore,
                  child: const Text(AppStrings.retry),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsModel.instance;
    final hasClient = settings.isValid;

    void openSettings() {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    }

    return Scaffold(
      key: _scaffoldKey,
      drawer: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 780) {
            return const SizedBox.shrink();
          }

          return Drawer(
            width: 244,
            backgroundColor: const Color(0xFF1A1A1A),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            child: _LibrarySidebar(
              compact: false,
              onDeckEntries: _sidebarOnDeckEntries,
              onRandomPick: () {
                Navigator.of(context).maybePop();
                _pickRandomArchive();
              },
              onOpenSettings: () {
                Navigator.of(context).maybePop();
                openSettings();
              },
              onOpenOnDeck: (entry) {
                Navigator.of(context).maybePop();
                _openOnDeckEntry(entry);
              },
              isPickingRandom: _isPickingRandom,
              isLoadingOnDeck: _isLoadingOnDeck,
              onDeckMessage: _onDeckMessage,
              onDeckMessageIsError: _onDeckMessageIsError,
              randomPickMessage: _randomPickMessage,
              randomPickMessageIsError: _randomPickMessageIsError,
            ),
          );
        },
      ),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(52),
        child: _TopBar(
          onRefresh: () {
            unawaited(_refreshVisibleDataInBackground());
          },
          isRefreshLoading: _isRefreshRevalidating,
          onOpenSidebarMenu: () => _scaffoldKey.currentState?.openDrawer(),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const fullSidebarWidth = 220.0;
          const compactSidebarWidth = 68.0;
          final useDrawerSidebar = constraints.maxWidth < 780;
          final useCompactSidebar =
              !useDrawerSidebar && constraints.maxWidth < 1120;
          final sidebarWidth = useDrawerSidebar
              ? 0.0
              : (useCompactSidebar ? compactSidebarWidth : fullSidebarWidth);

          return Row(
            children: [
              if (!useDrawerSidebar)
                SizedBox(
                  width: sidebarWidth,
                  child: _LibrarySidebar(
                    compact: useCompactSidebar,
                    onDeckEntries: _sidebarOnDeckEntries,
                    onRandomPick: _pickRandomArchive,
                    onOpenSettings: openSettings,
                    onOpenOnDeck: _openOnDeckEntry,
                    isPickingRandom: _isPickingRandom,
                    isLoadingOnDeck: _isLoadingOnDeck,
                    onDeckMessage: _onDeckMessage,
                    onDeckMessageIsError: _onDeckMessageIsError,
                    randomPickMessage: _randomPickMessage,
                    randomPickMessageIsError: _randomPickMessageIsError,
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, mainConstraints) {
                    final drawerWidth = mainConstraints.maxWidth
                        .clamp(0.0, 380.0)
                        .toDouble();
                    const outerHorizontalPadding = 24.0;
                    final contentWidth =
                        (mainConstraints.maxWidth - outerHorizontalPadding)
                            .clamp(120.0, double.infinity);

                    final mainContent = _LibraryMainContent(
                      controller: _controller,
                      focusNode: _focusNode,
                      suggestions: _suggestions,
                      highlightedSuggestionIndex: _highlightedSuggestionIndex,
                      toolbar: _buildToolbar(),
                      content: hasClient
                          ? _buildLibraryContent(context, contentWidth)
                          : _LibraryUnconfiguredView(onConfigure: openSettings),
                      onSearchKeyEvent: _handleSearchKeyEvent,
                      onSearchTap: _updateSuggestions,
                      onSearchSubmitted: _handleSearchSubmitted,
                      onClearSearch: () {
                        _pushLibraryHistoryIfNeeded(
                          _LibraryHistoryEntry(
                            searchQuery: '',
                            selectedCategoryId: _selectedCategoryId,
                            sortField: _selectedSort.id,
                            sortOrder: _sortOrder,
                            newOnly: _newOnly,
                            untagged: _untaggedOnly,
                            hideCompleted: _hideCompleted,
                          ),
                        );
                        _controller.clear();
                        _reloadLibrary(query: '');
                      },
                      onSuggestionTap: _applySuggestion,
                    );

                    return Stack(
                      children: [
                        mainContent,
                        if (_isDetailsOpen)
                          Positioned(
                            top: 0,
                            left: 0,
                            bottom: 0,
                            right: 0,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: _closeArchiveDetails,
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  color: Colors.black.withValues(alpha: 0.22),
                                ),
                              ),
                            ),
                          ),
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          top: 0,
                          bottom: 0,
                          width: drawerWidth,
                          right: _isDetailsOpen ? 0 : -drawerWidth,
                          child: _ArchiveDetailsDrawer(
                            archive: _selectedArchive,
                            categories: _selectedArchiveCategories,
                            availableStaticCategories: _categories
                                .where((category) => category.isStatic)
                                .toList(growable: false),
                            isLoadingCategories:
                                _isLoadingSelectedArchiveCategories,
                            isUpdatingCategories:
                                _isUpdatingSelectedArchiveCategories,
                            isUpdatingRating:
                              _isUpdatingSelectedArchiveRating,
                            isDeletingArchive: _isDeletingSelectedArchive,
                            currentRating: _selectedArchive == null
                              ? null
                              : _archiveRatingFromTags(
                                _selectedArchive!.parsedTags,
                                ),
                            categoryMessage: _selectedArchiveCategoryMessage,
                            categoryMessageIsError:
                                _selectedArchiveCategoryMessageIsError,
                            groupedTags: _selectedArchive == null
                                ? const []
                                : _groupArchiveTags(_selectedArchive!),
                            onClose: _closeArchiveDetails,
                            onRead: _readSelectedArchive,
                            onDelete: _deleteSelectedArchive,
                            onRatingSelected: _updateSelectedArchiveRating,
                            onTagSelected: _applyTagFilter,
                            onAddToCategory: _addSelectedArchiveToCategory,
                            onRemoveFromCategory:
                                _removeSelectedArchiveFromCategory,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ResetFiltersButton extends StatefulWidget {
  const _ResetFiltersButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_ResetFiltersButton> createState() => _ResetFiltersButtonState();
}

class _ResetFiltersButtonState extends State<_ResetFiltersButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _hovered ? const Color(0xFF49D7E8) : AppTheme.textMuted;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Text(
            '✕ Reset',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryHistoryBackButton extends StatefulWidget {
  const _LibraryHistoryBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_LibraryHistoryBackButton> createState() =>
      _LibraryHistoryBackButtonState();
}

class _LibraryHistoryBackButtonState extends State<_LibraryHistoryBackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _hovered ? AppTheme.textPrimary : AppTheme.textMuted;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(Icons.arrow_back, size: 18, color: color),
        ),
      ),
    );
  }
}

class _LibraryMainContent extends StatelessWidget {
  const _LibraryMainContent({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.highlightedSuggestionIndex,
    required this.toolbar,
    required this.content,
    required this.onSearchKeyEvent,
    required this.onSearchTap,
    required this.onSearchSubmitted,
    required this.onClearSearch,
    required this.onSuggestionTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<_SearchSuggestion> suggestions;
  final int highlightedSuggestionIndex;
  final Widget toolbar;
  final Widget content;
  final KeyEventResult Function(KeyEvent event) onSearchKeyEvent;
  final VoidCallback onSearchTap;
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback onClearSearch;
  final ValueChanged<_SearchSuggestion> onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        children: [
          _LibrarySearchField(
            controller: controller,
            focusNode: focusNode,
            onSearchKeyEvent: onSearchKeyEvent,
            onTap: onSearchTap,
            onSubmitted: onSearchSubmitted,
            onClear: onClearSearch,
          ),
          const SizedBox(height: 8),
          toolbar,
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            _LibrarySuggestionList(
              suggestions: suggestions,
              highlightedSuggestionIndex: highlightedSuggestionIndex,
              onSuggestionTap: onSuggestionTap,
            ),
          ],
          const SizedBox(height: 8),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _LibrarySearchField extends StatelessWidget {
  const _LibrarySearchField({
    required this.controller,
    required this.focusNode,
    required this.onSearchKeyEvent,
    required this.onTap,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final KeyEventResult Function(KeyEvent event) onSearchKeyEvent;
  final VoidCallback onTap;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (_, event) => onSearchKeyEvent(event),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onTap: onTap,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: AppStrings.librarySearchHint,
          isDense: true,
          prefixIcon: const Icon(
            Icons.search,
            size: 18,
            color: AppTheme.textMuted,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(onPressed: onClear, icon: const Icon(Icons.close)),
        ),
      ),
    );
  }
}

class _LibrarySuggestionList extends StatelessWidget {
  const _LibrarySuggestionList({
    required this.suggestions,
    required this.highlightedSuggestionIndex,
    required this.onSuggestionTap,
  });

  final List<_SearchSuggestion> suggestions;
  final int highlightedSuggestionIndex;
  final ValueChanged<_SearchSuggestion> onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    return TextFieldTapRegion(
      child: Material(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: suggestions.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final suggestion = suggestions[index];
              final isHighlighted = index == highlightedSuggestionIndex;
              return ListTile(
                dense: true,
                selected: isHighlighted,
                selectedTileColor: AppTheme.crimson.withValues(alpha: 0.14),
                onTap: () => onSuggestionTap(suggestion),
                leading: _SuggestionBadge(label: suggestion.kindLabel),
                title: Text(
                  suggestion.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LibraryUnconfiguredView extends StatelessWidget {
  const _LibraryUnconfiguredView({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(AppStrings.noServerConfigured),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: onConfigure,
            child: const Text(AppStrings.configure),
          ),
        ],
      ),
    );
  }
}

class _LibraryLoadErrorView extends StatelessWidget {
  const _LibraryLoadErrorView({
    required this.message,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              ElevatedButton(
                onPressed: onRetry,
                child: const Text(AppStrings.retry),
              ),
              OutlinedButton(
                onPressed: onOpenSettings,
                child: const Text(AppStrings.settingsTitle),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LibraryEmptyView extends StatelessWidget {
  const _LibraryEmptyView({required this.onRefresh});

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(AppStrings.noArchivesFound),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRefresh,
            child: const Text(AppStrings.refresh),
          ),
        ],
      ),
    );
  }
}

class _SearchSuggestion {
  const _SearchSuggestion({
    required this.label,
    required this.filterValue,
    required this.kind,
    required this.weight,
    required this.priority,
  });

  factory _SearchSuggestion.fromTagStat(LanraragiTagStat stat) {
    final colonIndex = stat.value.indexOf(':');
    final kind = colonIndex == -1
        ? 'tag'
        : stat.value.substring(0, colonIndex).trim();
    return _SearchSuggestion(
      label: stat.value,
      filterValue: stat.value,
      kind: kind,
      weight: stat.weight,
      priority: 0,
    );
  }

  final String label;
  final String filterValue;
  final String kind;
  final int weight;
  final int priority;

  String get kindLabel {
    if (kind == 'tag') {
      return 'tag';
    }
    return kind;
  }
}

class _SuggestionBadge extends StatelessWidget {
  const _SuggestionBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF252B36),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: Colors.white70),
        ),
      ),
    );
  }
}

class _ToolbarMenuOption<T> {
  const _ToolbarMenuOption({required this.value, required this.label});

  final T value;
  final String label;
}

class _ToolbarMenuButton<T> extends StatelessWidget {
  const _ToolbarMenuButton({
    required this.width,
    required this.label,
    required this.items,
    required this.onSelected,
    this.footerLabel,
    this.footerOnPressed,
    this.itemHoverColor,
  });

  final double width;
  final String label;
  final List<_ToolbarMenuOption<T>> items;
  final ValueChanged<T?> onSelected;
  final String? footerLabel;
  final VoidCallback? footerOnPressed;
  final Color? itemHoverColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedItemHoverColor =
        itemHoverColor ?? AppTheme.crimson.withValues(alpha: 0.14);
    final itemButtonStyle = ButtonStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: WidgetStatePropertyAll(Size(width, 36)),
      maximumSize: WidgetStatePropertyAll(Size(width, 36)),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return resolvedItemHoverColor;
        }
        return const Color(0xFF1E1E1E);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return AppTheme.textPrimary;
        }
        return AppTheme.textSecondary;
      }),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
    );
    final menuChildren = <Widget>[
      ...items.map(
        (item) => MenuItemButton(
          onPressed: () => onSelected(item.value),
          closeOnActivate: true,
          style: itemButtonStyle,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Colors.transparent, width: 2),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ),
      ),
    ];

    if (footerLabel != null && footerOnPressed != null) {
      if (menuChildren.isNotEmpty) {
        menuChildren.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, thickness: 0.5, color: AppTheme.border),
          ),
        );
      }
      menuChildren.add(
        MenuItemButton(
          onPressed: footerOnPressed,
          closeOnActivate: true,
          style: itemButtonStyle,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Text(
                footerLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.crimson,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      child: MenuAnchor(
        style: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Color(0xFF1E1E1E)),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Colors.black54),
          elevation: WidgetStatePropertyAll(10),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: AppTheme.border, width: 0.5),
            ),
          ),
        ),
        menuChildren: menuChildren,
        builder: (context, controller, child) {
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              behavior: HitTestBehavior.opaque,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border.fromBorderSide(
                    BorderSide(color: AppTheme.border, width: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.expand_more,
                        size: 16,
                        color: AppTheme.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

enum _CategoryContextAction { edit, delete }

class _CategoryFilterMenu extends StatelessWidget {
  const _CategoryFilterMenu({
    required this.width,
    required this.label,
    required this.staticCategories,
    required this.dynamicCategories,
    required this.selectedCategoryId,
    required this.onSelected,
    required this.onCreateCategory,
    required this.onEditCategory,
    required this.onDeleteCategory,
  });

  final double width;
  final String label;
  final List<LanraragiCategory> staticCategories;
  final List<LanraragiCategory> dynamicCategories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onSelected;
  final VoidCallback onCreateCategory;
  final ValueChanged<LanraragiCategory> onEditCategory;
  final ValueChanged<LanraragiCategory> onDeleteCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = MenuController();
    final maxMenuHeight = MediaQuery.sizeOf(context).height * 0.7;
    final staticSectionHeight = staticCategories.length * 36.0;
    final fixedHeight =
        36.0 +
        (staticCategories.isNotEmpty ? 22.0 + staticSectionHeight : 0.0) +
        (staticCategories.isNotEmpty && dynamicCategories.isNotEmpty ? 9.0 : 0.0) +
        (dynamicCategories.isNotEmpty ? 22.0 : 0.0) +
        9.0 +
        36.0;
    final dynamicSectionMaxHeight =
        maxMenuHeight > fixedHeight ? maxMenuHeight - fixedHeight : 0.0;

    return SizedBox(
      width: width,
      child: MenuAnchor(
        controller: controller,
        style: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Color(0xFF1E1E1E)),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          shadowColor: WidgetStatePropertyAll(Colors.black54),
          elevation: WidgetStatePropertyAll(10),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
              side: BorderSide(color: AppTheme.border, width: 0.5),
            ),
          ),
        ),
        menuChildren: [
          _CategoryFilterMenuItem(
            width: width,
            label: AppStrings.allCategories,
            selected: selectedCategoryId == null,
            onSelect: () {
              controller.close();
              onSelected(null);
            },
          ),
          if (staticCategories.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _CategoryMenuSectionHeader(label: 'STATIC'),
            ),
            ...staticCategories.map(
            (category) => _CategoryFilterMenuItem(
              width: width,
              label: category.name,
              selected: selectedCategoryId == category.id,
              leadingIcon: Icons.folder_outlined,
              onSelect: () {
                controller.close();
                onSelected(category.id);
              },
              onActionSelected: (action) {
                controller.close();
                switch (action) {
                  case _CategoryContextAction.edit:
                    onEditCategory(category);
                  case _CategoryContextAction.delete:
                    onDeleteCategory(category);
                }
              },
            ),
          ),
          ],
          if (staticCategories.isNotEmpty && dynamicCategories.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Divider(height: 1, thickness: 0.5, color: AppTheme.border),
            ),
          if (dynamicCategories.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _CategoryMenuSectionHeader(label: 'DYNAMIC'),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: dynamicSectionMaxHeight),
              child: _Scrollbarless(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: dynamicCategories
                        .map(
                          (category) => _CategoryFilterMenuItem(
                            width: width,
                            label: category.name,
                            selected: selectedCategoryId == category.id,
                            leadingIcon: Icons.bolt_rounded,
                            onSelect: () {
                              controller.close();
                              onSelected(category.id);
                            },
                            onActionSelected: (action) {
                              controller.close();
                              switch (action) {
                                case _CategoryContextAction.edit:
                                  onEditCategory(category);
                                case _CategoryContextAction.delete:
                                  onDeleteCategory(category);
                              }
                            },
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Divider(height: 1, thickness: 0.5, color: AppTheme.border),
          ),
          _CategoryFilterMenuItem(
            width: width,
            label: AppStrings.newCategoryMenuItem,
            highlightColor: AppTheme.crimson.withValues(alpha: 0.14),
            textColor: AppTheme.crimson,
            onSelect: () {
              controller.close();
              onCreateCategory();
            },
          ),
        ],
        builder: (context, controller, child) {
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                if (controller.isOpen) {
                  controller.close();
                } else {
                  controller.open();
                }
              },
              behavior: HitTestBehavior.opaque,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border.fromBorderSide(
                    BorderSide(color: AppTheme.border, width: 0.5),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.expand_more,
                        size: 16,
                        color: AppTheme.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FiltersMenuButton extends StatelessWidget {
  const _FiltersMenuButton({
    required this.newOnly,
    required this.untaggedOnly,
    required this.hideCompleted,
    required this.onToggleNewOnly,
    required this.onToggleUntagged,
    required this.onToggleHideCompleted,
  });

  final bool newOnly;
  final bool untaggedOnly;
  final bool hideCompleted;
  final VoidCallback onToggleNewOnly;
  final VoidCallback onToggleUntagged;
  final VoidCallback onToggleHideCompleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MenuAnchor(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF1E1E1E)),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.black54),
        elevation: WidgetStatePropertyAll(10),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: AppTheme.border, width: 0.5),
          ),
        ),
      ),
      menuChildren: [
        _FilterCheckboxMenuRow(
          label: AppStrings.filterNewOnly,
          value: newOnly,
          onChanged: (_) => onToggleNewOnly(),
        ),
        _FilterCheckboxMenuRow(
          label: AppStrings.filterUntagged,
          value: untaggedOnly,
          onChanged: (_) => onToggleUntagged(),
        ),
        _FilterCheckboxMenuRow(
          label: AppStrings.filterHideCompleted,
          value: hideCompleted,
          onChanged: (_) => onToggleHideCompleted(),
        ),
      ],
      builder: (context, controller, child) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            behavior: HitTestBehavior.opaque,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: AppTheme.surface,
                border: Border.fromBorderSide(
                  BorderSide(color: AppTheme.border, width: 0.5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppStrings.filters,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.expand_more,
                      size: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FilterCheckboxMenuRow extends StatelessWidget {
  const _FilterCheckboxMenuRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = value
        ? const Color(0xFF49D7E8)
        : AppTheme.textMuted;

    return InkWell(
      onTap: () => onChanged(!value),
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: value ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (value)
              const Icon(Icons.done, size: 14, color: Color(0xFF49D7E8)),
          ],
        ),
      ),
    );
  }
}

class _CategoryMenuSectionHeader extends StatelessWidget {
  const _CategoryMenuSectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppTheme.textMuted,
          fontWeight: FontWeight.w600,
          fontSize: 10,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _CategoryFilterMenuItem extends StatefulWidget {
  const _CategoryFilterMenuItem({
    required this.width,
    required this.label,
    required this.onSelect,
    this.onActionSelected,
    this.highlightColor,
    this.textColor,
    this.selected = false,
    this.leadingIcon,
  });

  final double width;
  final String label;
  final VoidCallback onSelect;
  final ValueChanged<_CategoryContextAction>? onActionSelected;
  final Color? highlightColor;
  final Color? textColor;
  final bool selected;
  final IconData? leadingIcon;

  @override
  State<_CategoryFilterMenuItem> createState() =>
      _CategoryFilterMenuItemState();
}

class _CategoryFilterMenuItemState extends State<_CategoryFilterMenuItem> {
  bool _hovered = false;

  Future<void> _showContextMenu(Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    final overlayBox = overlay is RenderBox ? overlay : null;
    if (overlayBox == null || widget.onActionSelected == null) {
      return;
    }

    final action = await showMenu<_CategoryContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlayBox.size.width - position.dx,
        overlayBox.size.height - position.dy,
      ),
      color: const Color(0xFF1A1A1A),
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      items: const [
        PopupMenuItem<_CategoryContextAction>(
          value: _CategoryContextAction.edit,
          mouseCursor: SystemMouseCursors.click,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Text(AppStrings.edit),
          ),
        ),
        PopupMenuItem<_CategoryContextAction>(
          value: _CategoryContextAction.delete,
          mouseCursor: SystemMouseCursors.click,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Text(AppStrings.delete),
          ),
        ),
      ],
    );

    if (!mounted || action == null) {
      return;
    }
    widget.onActionSelected!(action);
  }

  @override
  Widget build(BuildContext context) {
    final highlightColor =
        widget.highlightColor ?? AppTheme.crimson.withValues(alpha: 0.14);
    final foregroundColor = widget.textColor ??
        (widget.selected ? const Color(0xFF49D7E8) : AppTheme.textPrimary);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: SizedBox(
        width: widget.width,
        height: 36,
        child: Material(
          color: _hovered ? highlightColor : const Color(0xFF1E1E1E),
          child: InkWell(
            onTap: widget.onSelect,
            mouseCursor: SystemMouseCursors.click,
            onSecondaryTapDown: widget.onActionSelected == null
                ? null
                : (details) => _showContextMenu(details.globalPosition),
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  if (widget.leadingIcon != null) ...[
                    Icon(widget.leadingIcon, size: 14, color: foregroundColor),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: foregroundColor,
                        fontWeight:
                            widget.selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.done, size: 14, color: Color(0xFF49D7E8)),
                    ),
                  if (widget.onActionSelected != null)
                    IconButton(
                      onPressed: () async {
                        final box = context.findRenderObject();
                        final renderBox = box is RenderBox ? box : null;
                        if (renderBox == null) {
                          return;
                        }
                        final topRight = renderBox.localToGlobal(
                          Offset(renderBox.size.width, 0),
                        );
                        await _showContextMenu(topRight);
                      },
                      mouseCursor: SystemMouseCursors.click,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      splashRadius: 16,
                      icon: const Icon(
                        Icons.more_horiz,
                        size: 16,
                        color: AppTheme.textSecondary,
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

class _GroupedTagNamespace {
  const _GroupedTagNamespace({required this.namespace, required this.tags});

  final String namespace;
  final List<String> tags;
}

class _ArchiveDetailsDrawer extends StatelessWidget {
  const _ArchiveDetailsDrawer({
    required this.archive,
    required this.categories,
    required this.availableStaticCategories,
    required this.isLoadingCategories,
    required this.isUpdatingCategories,
    required this.isUpdatingRating,
    required this.isDeletingArchive,
    required this.currentRating,
    required this.categoryMessage,
    required this.categoryMessageIsError,
    required this.groupedTags,
    required this.onClose,
    required this.onRead,
    required this.onDelete,
    required this.onRatingSelected,
    required this.onTagSelected,
    required this.onAddToCategory,
    required this.onRemoveFromCategory,
  });

  final Archive? archive;
  final List<LanraragiCategory> categories;
  final List<LanraragiCategory> availableStaticCategories;
  final bool isLoadingCategories;
  final bool isUpdatingCategories;
  final bool isUpdatingRating;
  final bool isDeletingArchive;
  final int? currentRating;
  final String? categoryMessage;
  final bool categoryMessageIsError;
  final List<_GroupedTagNamespace> groupedTags;
  final VoidCallback onClose;
  final VoidCallback onRead;
  final VoidCallback onDelete;
  final ValueChanged<int> onRatingSelected;
  final ValueChanged<String> onTagSelected;
  final ValueChanged<String> onAddToCategory;
  final ValueChanged<String> onRemoveFromCategory;

  String _tagLabel(String namespace, String rawTag) {
    final separatorIndex = rawTag.indexOf(':');
    final value = separatorIndex == -1
        ? rawTag.trim()
        : rawTag.substring(separatorIndex + 1).trim();
    final formattedDate = _tryFormatTagDate(namespace, value);
    if (formattedDate != null) {
      return formattedDate;
    }
    return value;
  }

  String? _tryFormatTagDate(String namespace, String value) {
    final normalizedNamespace = namespace.toLowerCase();
    if (!normalizedNamespace.contains('date') &&
        !normalizedNamespace.contains('time')) {
      return null;
    }

    final epochValue = int.tryParse(value);
    if (epochValue == null) {
      return null;
    }

    final timestamp = epochValue < 1000000000000
        ? epochValue * 1000
        : epochValue;
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$month/$day/${date.year}';
  }

  Future<void> _openSourceUrl(String sourceUrl) async {
    final uri = Uri.tryParse(sourceUrl);
    if (uri == null) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _buildSectionLabel(BuildContext context, String label) {
    return Text(
      label.replaceAll('_', ' ').toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: const Color(0xFF666666),
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.18,
      ),
    );
  }

  List<LanraragiCategory> get _addableStaticCategories {
    final existingIds = categories.map((category) => category.id).toSet();
    return availableStaticCategories
        .where((category) => !existingIds.contains(category.id))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      elevation: 24,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: AppTheme.border, width: 0.5)),
        ),
        child: SafeArea(
          left: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
                child: Row(
                  children: [
                    const Spacer(),
                    IconButton(
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: archive == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AspectRatio(
                              aspectRatio: 2 / 3,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: ArchiveThumbnail(
                                  archive: archive!,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SelectableText(
                              archive!.title,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(color: AppTheme.textPrimary),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              archive!.pageCount == null
                                  ? 'Unknown page count'
                                  : '${archive!.pageCount} pages',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: AppTheme.textSecondary),
                            ),
                            const SizedBox(height: 10),
                            _ArchiveRatingRow(
                              currentRating: currentRating,
                              isUpdating: isUpdatingRating,
                              onSelected: onRatingSelected,
                            ),
                            const SizedBox(height: 16),
                            _buildSectionLabel(
                              context,
                              AppStrings.categoriesTitle,
                            ),
                            const SizedBox(height: 6),
                            if (isLoadingCategories)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else ...[
                                if (categories.isEmpty)
                                  Text(
                                    'Not in any categories.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: AppTheme.textSecondary,
                                        ),
                                  )
                                else
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: categories
                                        .map(
                                          (category) => InputChip(
                                            label: Text(category.name),
                                            onDeleted: isUpdatingCategories
                                                ? null
                                                : () => onRemoveFromCategory(
                                                    category.id,
                                                  ),
                                            deleteIconColor:
                                                AppTheme.textSecondary,
                                            backgroundColor: const Color(
                                              0xFF2A2A2A,
                                            ),
                                            labelStyle: const TextStyle(
                                              fontSize: 11,
                                              color: AppTheme.textPrimary,
                                              fontWeight: FontWeight.w500,
                                            ),
                                            side: BorderSide.none,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                          ),
                                        )
                                        .toList(growable: false),
                                  ),
                                const SizedBox(height: 8),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF202020),
                                    border: Border.all(
                                      color: AppTheme.border,
                                      width: 0.5,
                                    ),
                                  ),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return _ToolbarMenuButton<String>(
                                        width: constraints.maxWidth,
                                        label: _addableStaticCategories.isEmpty
                                            ? AppStrings.noStaticCategories
                                            : AppStrings.addToCategory,
                                        items: _addableStaticCategories
                                            .map(
                                              (category) =>
                                                  _ToolbarMenuOption<String>(
                                                    value: category.id,
                                                    label: category.name,
                                                  ),
                                            )
                                            .toList(growable: false),
                                        itemHoverColor: const Color(0xFF49D7E8),
                                        onSelected:
                                            isUpdatingCategories ||
                                                _addableStaticCategories.isEmpty
                                            ? (_) {}
                                            : (categoryId) {
                                                if (categoryId != null) {
                                                  onAddToCategory(categoryId);
                                                }
                                              },
                                      );
                                    },
                                  ),
                                ),
                                if (categoryMessage != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    categoryMessage!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: categoryMessageIsError
                                              ? AppTheme.crimson
                                              : AppTheme.textSecondary,
                                        ),
                                  ),
                                ],
                              ],
                            if (archive!.sourceUrl != null &&
                                archive!.sourceUrl!.trim().isNotEmpty) ...[
                              const SizedBox(height: 16),
                              _buildSectionLabel(context, 'Source'),
                              const SizedBox(height: 6),
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => _openSourceUrl(
                                    archive!.sourceUrl!.trim(),
                                  ),
                                  behavior: HitTestBehavior.opaque,
                                  child: Text(
                                    archive!.sourceUrl!.trim(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: AppTheme.crimson,
                                          decoration:
                                              TextDecoration.underline,
                                          decorationColor: AppTheme.crimson,
                                        ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            for (final namespace in groupedTags) ...[
                              _buildSectionLabel(
                                context,
                                namespace.namespace,
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: namespace.tags
                                    .map(
                                      (tag) => ActionChip(
                                        onPressed: () => onTagSelected(tag),
                                        mouseCursor: SystemMouseCursors.click,
                                        label: Text(
                                          _tagLabel(namespace.namespace, tag),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.crimson,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 0,
                                        ),
                                        visualDensity: const VisualDensity(
                                          horizontal: -2,
                                          vertical: -3,
                                        ),
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        backgroundColor: const Color(
                                          0xFF2A2A2A,
                                        ),
                                        side: BorderSide.none,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (groupedTags.isEmpty)
                              Text(
                                'No tags available.',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: AppTheme.textSecondary),
                              ),
                          ],
                        ),
                      ),
              ),
              if (archive != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: isDeletingArchive ? null : onDelete,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFDA7D86),
                            side: const BorderSide(
                              color: Color(0xFF6A343A),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            isDeletingArchive ? 'Deleting...' : 'Delete',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: isDeletingArchive ? null : onRead,
                          style: const ButtonStyle(
                            mouseCursor: WidgetStatePropertyAll(
                              SystemMouseCursors.click,
                            ),
                          ),
                          child: const Text('Read'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchiveRatingRow extends StatelessWidget {
  const _ArchiveRatingRow({
    required this.currentRating,
    required this.isUpdating,
    required this.onSelected,
  });

  final int? currentRating;
  final bool isUpdating;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(5, (index) {
        final starValue = index + 1;
        final isActive = currentRating != null && starValue <= currentRating!;
        return IconButton(
          onPressed: isUpdating ? null : () => onSelected(starValue),
          tooltip: '$starValue star${starValue == 1 ? '' : 's'}',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          mouseCursor: isUpdating
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          icon: Icon(
            Icons.star,
            size: 18,
            color: isActive ? const Color(0xFF49D7E8) : AppTheme.textMuted,
          ),
        );
      }),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onRefresh,
    required this.isRefreshLoading,
    this.onOpenSidebarMenu,
  });

  final VoidCallback onRefresh;
  final bool isRefreshLoading;
  final VoidCallback? onOpenSidebarMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: DragToMoveArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showSidebarMenuButton =
                  onOpenSidebarMenu != null && constraints.maxWidth < 780;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    if (showSidebarMenuButton) ...[
                      _TopBarIconButton(
                        icon: Icons.menu,
                        onPressed: onOpenSidebarMenu!,
                      ),
                      const SizedBox(width: 8),
                    ],
                    const Spacer(),
                    const SizedBox(width: 8),
                    _TopBarIconButton(
                      icon: Icons.refresh,
                      isLoading: isRefreshLoading,
                      onPressed: onRefresh,
                    ),
                    const SizedBox(width: 8),
                    const WindowControls(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LibrarySidebar extends StatelessWidget {
  static const _appIconAsset = 'assets/icon/app_icon.png';

  const _LibrarySidebar({
    required this.compact,
    required this.onDeckEntries,
    required this.onRandomPick,
    required this.onOpenSettings,
    required this.onOpenOnDeck,
    required this.isPickingRandom,
    required this.isLoadingOnDeck,
    required this.onDeckMessage,
    required this.onDeckMessageIsError,
    required this.randomPickMessage,
    required this.randomPickMessageIsError,
  });

  final bool compact;
  final List<OnDeckEntry> onDeckEntries;
  final VoidCallback onRandomPick;
  final VoidCallback onOpenSettings;
  final ValueChanged<OnDeckEntry> onOpenOnDeck;
  final bool isPickingRandom;
  final bool isLoadingOnDeck;
  final String? onDeckMessage;
  final bool onDeckMessageIsError;
  final String? randomPickMessage;
  final bool randomPickMessageIsError;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        border: Border(right: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      child: SafeArea(
        bottom: false,
        child: compact ? _buildCompact(context) : _buildExpanded(context),
      ),
    );
  }

  Widget _buildBrandIcon(double size, {double radius = 8}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        _appIconAsset,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildBrandIcon(34),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppStrings.appTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isPickingRandom ? null : onRandomPick,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF49D7E8),
                foregroundColor: const Color(0xFF03161A),
                disabledBackgroundColor: const Color(0xFF2C6670),
                disabledForegroundColor: const Color(0xFFB4DDE3),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: isPickingRandom
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.casino_outlined, size: 18),
              label: Text(
                isPickingRandom
                    ? AppStrings.pickingRandom
                    : AppStrings.randomPick,
              ),
            ),
          ),
          if (randomPickMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              randomPickMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: randomPickMessageIsError
                    ? AppTheme.crimson
                    : AppTheme.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Expanded(
            child: _Scrollbarless(
              child: ListView(
                children: [
                  Text(
                    AppStrings.onDeckTitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.textMuted,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isLoadingOnDeck)
                    const Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (onDeckEntries.isEmpty)
                    Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        onDeckMessage ?? AppStrings.recentInProgressPlaceholder,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onDeckMessageIsError
                              ? AppTheme.crimson
                              : AppTheme.textMuted,
                        ),
                      ),
                    )
                  else
                    ...onDeckEntries.indexed.expand(
                      (entry) => [
                        if (entry.$1 > 0)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Divider(
                              height: 1,
                              thickness: 0.5,
                              color: AppTheme.border,
                            ),
                          ),
                        _OnDeckCoverTile(
                          entry: entry.$2,
                          onTap: () => onOpenOnDeck(entry.$2),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SidebarActionTile(
            icon: Icons.settings,
            label: AppStrings.settingsTitle,
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildCompact(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
      child: Column(
        children: [
          _buildBrandIcon(36),
          const SizedBox(height: 14),
          Tooltip(
            message: isPickingRandom
                ? AppStrings.pickingRandomTooltip
                : AppStrings.randomPick,
            child: _SidebarIconButton(
              icon: isPickingRandom
                  ? Icons.hourglass_top
                  : Icons.casino_outlined,
              onTap: isPickingRandom ? null : onRandomPick,
              accent: const Color(0xFF49D7E8),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: _Scrollbarless(
              child: ListView(
                children: [
                  if (isLoadingOnDeck)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Align(
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  for (final entry in onDeckEntries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message:
                            '${entry.title}\n${entry.currentPage} / ${entry.totalPages}',
                        child: _CompactOnDeckThumb(
                          entry: entry,
                          onTap: () => onOpenOnDeck(entry),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Tooltip(
            message: AppStrings.settingsTitle,
            child: _SidebarIconButton(
              icon: Icons.settings,
              onTap: onOpenSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnDeckCoverTile extends StatelessWidget {
  const _OnDeckCoverTile({required this.entry, required this.onTap});

  final OnDeckEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                height: 110,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ArchiveThumbnail(
                    archive: Archive(id: entry.archiveId, title: entry.title),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${entry.currentPage} / ${entry.totalPages}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF7ACED9),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactOnDeckThumb extends StatelessWidget {
  const _CompactOnDeckThumb({required this.entry, required this.onTap});

  final OnDeckEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          width: 44,
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border, width: 0.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ArchiveThumbnail(
              archive: Archive(id: entry.archiveId, title: entry.title),
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarActionTile extends StatelessWidget {
  const _SidebarActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF202020),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 10),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryDialogResult {
  const _CategoryDialogResult({
    required this.name,
    required this.search,
    required this.pinned,
  });

  final String name;
  final String search;
  final bool pinned;
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({
    required this.title,
    required this.submitLabel,
    this.initialName = '',
    this.initialSearch = '',
    this.initialPinned = false,
  });

  final String title;
  final String submitLabel;
  final String initialName;
  final String initialSearch;
  final bool initialPinned;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName;
    _searchController.text = widget.initialSearch;
    _pinned = widget.initialPinned;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: const Color(0xFF202020),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: Color(0xFF2A2E39), width: 1),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: Color(0xFF2A2E39), width: 1),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: Color(0xFF49D7E8), width: 1),
      ),
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      _CategoryDialogResult(
        name: name,
        search: _searchController.text.trim(),
        pinned: _pinned,
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String label) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: AppTheme.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                _fieldLabel(context, AppStrings.categoryNameLabel),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                  decoration: _fieldDecoration(),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 10),
                _fieldLabel(context, AppStrings.categorySearchLabel),
                const SizedBox(height: 4),
                Text(
                  AppStrings.categorySearchHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _searchController,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                  decoration: _fieldDecoration(),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 10),
                Theme(
                  data: theme.copyWith(
                    checkboxTheme: CheckboxThemeData(
                      fillColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return const Color(0xFF49D7E8);
                        }
                        return Colors.transparent;
                      }),
                      checkColor: const WidgetStatePropertyAll(
                        Color(0xFF03161A),
                      ),
                      side: const BorderSide(
                        color: Color(0xFF49D7E8),
                        width: 1,
                      ),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                  ),
                  child: InkWell(
                    onTap: () => setState(() => _pinned = !_pinned),
                    mouseCursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _pinned,
                            onChanged: (value) =>
                                setState(() => _pinned = value ?? false),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: const VisualDensity(
                              horizontal: -4,
                              vertical: -4,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            AppStrings.categoryPinnedLabel,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      child: const Text(AppStrings.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF49D7E8),
                        foregroundColor: const Color(0xFF03161A),
                        elevation: 0,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        textStyle: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(widget.submitLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteCategoryDialog extends StatelessWidget {
  const _DeleteCategoryDialog({required this.categoryName});

  final String categoryName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.deleteCategory,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  AppStrings.deleteCategoryConfirmation,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  categoryName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  AppStrings.deleteCategoryWarning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      child: const Text(AppStrings.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF49D7E8),
                        foregroundColor: const Color(0xFF03161A),
                        elevation: 0,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        textStyle: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text(AppStrings.delete),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteArchiveDialog extends StatelessWidget {
  const _DeleteArchiveDialog({required this.archiveTitle});

  final String archiveTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Container(
            color: const Color(0xFF1A1A1A),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Delete Archive',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Are you sure you want to delete this archive? This cannot be undone.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  archiveTitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text(AppStrings.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8A3D45),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        textStyle: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarIconButton extends StatelessWidget {
  const _SidebarIconButton({
    required this.icon,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent ?? const Color(0xFF202020),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        mouseCursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: accent == null
                ? AppTheme.textSecondary
                : const Color(0xFF03161A),
          ),
        ),
      ),
    );
  }
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

class _TopBarIconButton extends StatefulWidget {
  const _TopBarIconButton({
    required this.icon,
    required this.onPressed,
    this.isLoading = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool isLoading;

  @override
  State<_TopBarIconButton> createState() => _TopBarIconButtonState();
}

class _TopBarIconButtonState extends State<_TopBarIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.isLoading
          ? SystemMouseCursors.progress
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.isLoading ? null : widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 28,
          height: 28,
          child: widget.isLoading
              ? const Padding(
                  padding: EdgeInsets.all(5),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  widget.icon,
                  size: 18,
                  color: _hovered
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                ),
        ),
      ),
    );
  }
}

