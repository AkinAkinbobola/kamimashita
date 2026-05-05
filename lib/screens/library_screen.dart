import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../api/lanraragi_client.dart';
import '../models/archive.dart';
import '../providers/settings_provider.dart';
import '../utils/app_strings.dart';
import '../widgets/cover_card.dart';
import '../widgets/theme.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

/// Main library, search, and archive-entry screen for the app.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
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
  String _sortBy = 'title';
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

  bool get _isDetailsOpen => _selectedArchive != null;

  @override
  void initState() {
    super.initState();
    SettingsModel.instance.addListener(_onSettingsChanged);
    _controller.addListener(_onQueryChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCategories();
      _refreshOnDeck();
      _reloadLibrary();
    });
  }

  void _onSettingsChanged() {
    final settings = SettingsModel.instance;
    final nextKey = '${settings.serverUrl}|${settings.apiKey}';
    final connectionChanged = nextKey != _settingsConnectionKey;

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
      });
    }
  }

  @override
  void dispose() {
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
    if (!_scrollController.hasClients || _isInitialLoading || _isLoadingMore || !_hasMore) {
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

  void _search(String q) {
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

    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
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
        _highlightedSuggestionIndex = (_highlightedSuggestionIndex + offset) % _suggestions.length;
        if (_highlightedSuggestionIndex < 0) {
          _highlightedSuggestionIndex += _suggestions.length;
        }
      }
    });
  }

  _SearchSuggestion? get _highlightedSuggestion {
    if (_highlightedSuggestionIndex < 0 || _highlightedSuggestionIndex >= _suggestions.length) {
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
    });
  }

  void _closeArchiveDetails() {
    if (!_isDetailsOpen) {
      return;
    }
    setState(() {
      _selectedArchive = null;
    });
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

      final seenIds = _items.map((archive) => archive.id).where((id) => id.isNotEmpty).toSet();
      final newItems = page.items.where((archive) {
        if (archive.id.isEmpty) {
          return true;
        }
        return !seenIds.contains(archive.id);
      }).toList(growable: false);

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
      sortBy: _sortBy,
      order: _sortOrder,
      newOnly: _newOnly,
      untaggedOnly: _untaggedOnly,
      hideCompleted: _hideCompleted,
    );
  }

  Future<void> _loadCategories() async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || _isLoadingCategories) {
      return;
    }

    final cacheKey = '${settings.serverUrl}|${LanraragiClient.normalizeApiKey(settings.apiKey)}';
    if (_categoriesCacheKey == cacheKey && _categories.isNotEmpty) {
      return;
    }

    _isLoadingCategories = true;
    final client = LanraragiClient(settings.serverUrl, settings.apiKey);
    try {
      final categories = await client.getCategories();
      if (!mounted) {
        return;
      }

      final selectedExists = _selectedCategoryId == null || categories.any((category) => category.id == _selectedCategoryId);
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

  void _prefetchThumbnails(List<Archive> archives) {
    if (!_isDesktopWindowControlsEnabled || archives.isEmpty || !mounted) {
      return;
    }

    final settings = SettingsModel.instance;
    if (!settings.isValid) {
      return;
    }

    final normalizedBase = _normalizeThumbnailBase(settings.serverUrl);
    final headers = settings.authHeader();
    final candidates = archives.where((archive) => archive.id.isNotEmpty).take(6).toList(growable: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      for (final archive in candidates) {
        final provider = CachedNetworkImageProvider(
          '$normalizedBase/api/archives/${archive.id}/thumbnail',
          headers: headers,
          cacheKey: 'archive-thumbnail-${archive.id}',
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
      final archive = _findLoadedArchive(entry.archiveId) ??
          await LanraragiClient(settings.serverUrl, settings.apiKey).getArchive(entry.archiveId);
      if (!mounted) {
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(
            archive: archive,
            initialPage: entry.currentPage,
          ),
        ),
      ).then((_) => _refreshOnDeck());
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
    final entries = SettingsModel.instance.onDeckEntries.take(4).toList(growable: false);
    setState(() {
      _sidebarOnDeckEntries = entries;
      _isLoadingOnDeck = false;
      _onDeckMessage = entries.isEmpty ? AppStrings.noRecentInProgressArchives : null;
      _onDeckMessageIsError = false;
    });
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
      final archives = await LanraragiClient(settings.serverUrl, settings.apiKey).getOnDeckArchives();
      if (!mounted) {
        return;
      }

      final entries = archives
          .where((archive) => archive.id.isNotEmpty && archive.title.trim().isNotEmpty)
          .take(4)
          .map(OnDeckEntry.fromArchive)
          .toList(growable: false);

      setState(() {
        _sidebarOnDeckEntries = entries;
        _isLoadingOnDeck = false;
        _onDeckMessage = entries.isEmpty ? AppStrings.noRecentInProgressArchives : null;
        _onDeckMessageIsError = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _sidebarOnDeckEntries = const <OnDeckEntry>[];
        _isLoadingOnDeck = false;
        _onDeckMessage = error.toString().replaceFirst('LanraragiException: ', '');
        _onDeckMessageIsError = true;
      });
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
      final pickedArchive = await LanraragiClient(settings.serverUrl, settings.apiKey)
          .getRandomArchive();

      if (!mounted) {
        return;
      }

      if (pickedArchive == null) {
        _setRandomPickMessage(AppStrings.noMatchingRandomArchive, isError: false);
        return;
      }

      setState(() {
        _selectedArchive = pickedArchive;
        _randomPickMessage = null;
        _randomPickMessageIsError = false;
      });
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

  String _normalizeThumbnailBase(String value) {
    var normalized = value.trim();
    normalized = normalized.replaceAll(RegExp(r',\s*$'), '');
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.toLowerCase().endsWith('/api')) {
      normalized = normalized.substring(0, normalized.length - 4);
    }
    return normalized;
  }

  Future<void> _ensureTagStatsLoaded() async {
    final settings = SettingsModel.instance;
    if (!settings.isValid || _isLoadingTagStats) {
      return;
    }

    final cacheKey = '${settings.serverUrl}|${LanraragiClient.normalizeApiKey(settings.apiKey)}';
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
      if ((_suggestions.isNotEmpty || _highlightedSuggestionIndex != -1) && mounted) {
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
          final suggestion = _SearchSuggestion(label: term, filterValue: term, kind: 'title', weight: 0, priority: 1);
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
    return query.substring(range.start, range.end).replaceAll('"', '').replaceAll(r'$', '').trim();
  }

  void _applySuggestion(_SearchSuggestion suggestion) {
    final currentText = _controller.text;
    final range = _activeTokenRange(currentText);
    final replacement = suggestion.filterValue + r'$, ';
    final prefix = currentText.substring(0, range.start);
    final suffix = currentText.substring(range.end).replaceFirst(RegExp(r'^[\s,-]+'), '');
    final nextText = '$prefix$replacement$suffix';

    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: prefix.length + replacement.length),
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

    if (!_isWrappedInQuotes(normalized)) {
      final colonIndex = normalized.indexOf(':');
      if (colonIndex > 0 && colonIndex < normalized.length - 1) {
        final namespace = normalized.substring(0, colonIndex + 1);
        final value = normalized.substring(colonIndex + 1).trim();
        if (value.contains(RegExp(r'\s')) && !_isWrappedInQuotes(value)) {
          normalized = '$namespace"$value"';
        }
      } else if (normalized.contains(RegExp(r'\s'))) {
        normalized = '"$normalized"';
      }
    }

    return hasExactSuffix ? normalized + r'$' : normalized + r'$';
  }

  bool _isWrappedInQuotes(String value) {
    return value.length >= 2 && value.startsWith('"') && value.endsWith('"');
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
    return character == ',' || character == '-' || RegExp(r'\s').hasMatch(character);
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
    if (value == null || value == _sortBy) {
      return;
    }
    setState(() {
      _sortBy = value;
    });
    _reloadLibrary();
  }

  void _toggleSortOrder() {
    setState(() {
      _sortOrder = _sortOrder == 'asc' ? 'desc' : 'asc';
    });
    _reloadLibrary();
  }

  void _updateCategory(String? value) {
    final nextValue = value == null || value.isEmpty ? null : value;
    if (nextValue == _selectedCategoryId) {
      return;
    }
    setState(() {
      _selectedCategoryId = nextValue;
    });
    _reloadLibrary();
  }

  void _toggleFlagFilter({
    required bool currentValue,
    required void Function(bool nextValue) apply,
    VoidCallback? onEnabled,
  }) {
    final nextValue = !currentValue;
    apply(nextValue);
    if (nextValue) {
      onEnabled?.call();
    }
    _reloadLibrary();
  }

  String _titleCase(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value[0].toUpperCase() + value.substring(1);
  }

  Widget _buildFilterToggle({required String label, required bool active, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: active ? AppTheme.crimson : AppTheme.textSecondary,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _sortLabel(String value) {
    return switch (value) {
      'title' => AppStrings.sortByTitle,
      'lastread' => AppStrings.sortByLastRead,
      _ => _titleCase(value),
    };
  }

  List<_GroupedTagNamespace> _groupArchiveTags(Archive archive) {
    final grouped = <String, List<String>>{};
    for (final rawTag in archive.parsedTags) {
      final separatorIndex = rawTag.indexOf(':');
      final namespace = separatorIndex == -1 ? 'tag' : rawTag.substring(0, separatorIndex).trim();
      final normalizedNamespace = namespace.isEmpty ? 'tag' : namespace;
      if (normalizedNamespace.toLowerCase() == 'source') {
        continue;
      }
      grouped.putIfAbsent(normalizedNamespace, () => <String>[]).add(rawTag);
    }

    const preferredOrder = ['artist', 'group', 'series', 'parody', 'character', 'language', 'tag'];
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
        .map((namespace) => _GroupedTagNamespace(namespace: namespace, tags: List.unmodifiable(grouped[namespace]!)))
        .toList(growable: false);
  }

  Widget _buildToolbar() {
    final namespaces = <String>{};
    for (final stat in _tagStats) {
      final separatorIndex = stat.value.indexOf(':');
      if (separatorIndex <= 0) {
        continue;
      }
      final namespace = stat.value.substring(0, separatorIndex).trim();
      if (namespace.isNotEmpty) {
        namespaces.add(namespace);
      }
    }

    final namespaceOptions = namespaces.toList()..sort();

    final compactFieldStyle = Theme.of(context).textTheme.bodyMedium;
    final sortOptions = ['title', 'lastread', ...namespaceOptions];

    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _ToolbarMenuButton<String>(
              width: 150,
              label: _sortLabel(_sortBy),
              items: sortOptions
                  .map(
                    (value) => _ToolbarMenuOption<String>(
                      value: value,
                      label: _sortLabel(value),
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
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                side: const BorderSide(color: AppTheme.border, width: 0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                foregroundColor: AppTheme.textSecondary,
              ),
              icon: Icon(_sortOrder == 'asc' ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
              label: Text(
                _sortOrder == 'asc' ? AppStrings.sortAscending : AppStrings.sortDescending,
                style: compactFieldStyle,
              ),
            ),
            if (_categories.isNotEmpty) ...[
              const SizedBox(width: 8),
              _ToolbarMenuButton<String?>(
                width: 190,
                label: _categories
                        .where((category) => category.id == _selectedCategoryId)
                        .map((category) => category.name)
                        .cast<String?>()
                        .firstOrNull ??
                    AppStrings.allCategories,
                items: [
                  const _ToolbarMenuOption<String?>(value: null, label: AppStrings.allCategories),
                  ..._categories.map(
                    (category) => _ToolbarMenuOption<String?>(
                      value: category.id,
                      label: category.name,
                    ),
                  ),
                ],
                onSelected: _updateCategory,
              ),
            ],
            const SizedBox(width: 8),
            ...[
              (
                AppStrings.filterNewOnly,
                _newOnly,
                () => _toggleFlagFilter(
                  currentValue: _newOnly,
                  apply: (value) => setState(() => _newOnly = value),
                  onEnabled: () => setState(() => _untaggedOnly = false),
                ),
              ),
              (
                AppStrings.filterUntagged,
                _untaggedOnly,
                () => _toggleFlagFilter(
                  currentValue: _untaggedOnly,
                  apply: (value) => setState(() => _untaggedOnly = value),
                  onEnabled: () => setState(() => _newOnly = false),
                ),
              ),
              (
                AppStrings.filterHideCompleted,
                _hideCompleted,
                () => _toggleFlagFilter(
                  currentValue: _hideCompleted,
                  apply: (value) => setState(() => _hideCompleted = value),
                ),
              ),
            ].map(
              (entry) => _buildFilterToggle(
                label: entry.$1,
                active: entry.$2,
                onTap: entry.$3,
              ),
            ),
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

    var columns = ((availableWidth + spacing) / (targetCardWidth + spacing)).floor().clamp(1, 8);
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
        onOpenSettings: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
                    _loadMoreError.toString().replaceFirst('LanraragiException: ', ''),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(onPressed: _loadMore, child: const Text(AppStrings.retry)),
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
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
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
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
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
          onRefresh: _loadLibrary,
          onOpenSidebarMenu: () => _scaffoldKey.currentState?.openDrawer(),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const fullSidebarWidth = 220.0;
          const compactSidebarWidth = 68.0;
          final useDrawerSidebar = constraints.maxWidth < 780;
          final useCompactSidebar = !useDrawerSidebar && constraints.maxWidth < 1120;
          final sidebarWidth = useDrawerSidebar ? 0.0 : (useCompactSidebar ? compactSidebarWidth : fullSidebarWidth);

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
                    final drawerWidth = mainConstraints.maxWidth.clamp(0.0, 380.0).toDouble();
                    const outerHorizontalPadding = 24.0;
                    final contentWidth = (mainConstraints.maxWidth - outerHorizontalPadding).clamp(120.0, double.infinity);

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
                            child: GestureDetector(
                              onTap: _closeArchiveDetails,
                              behavior: HitTestBehavior.opaque,
                              child: Container(color: Colors.black.withValues(alpha: 0.22)),
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
                            groupedTags: _selectedArchive == null ? const [] : _groupArchiveTags(_selectedArchive!),
                            onClose: _closeArchiveDetails,
                            onRead: _readSelectedArchive,
                            onTagSelected: _applyTagFilter,
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
          prefixIcon: const Icon(Icons.search, size: 18, color: AppTheme.textMuted),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close),
                ),
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
                title: Text(suggestion.label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          ElevatedButton(onPressed: onConfigure, child: const Text(AppStrings.configure)),
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
              ElevatedButton(onPressed: onRetry, child: const Text(AppStrings.retry)),
              OutlinedButton(onPressed: onOpenSettings, child: const Text(AppStrings.settingsTitle)),
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
          OutlinedButton(onPressed: onRefresh, child: const Text(AppStrings.refresh)),
        ],
      ),
    );
  }
}

class _SearchSuggestion {
  const _SearchSuggestion({required this.label, required this.filterValue, required this.kind, required this.weight, required this.priority});

  factory _SearchSuggestion.fromTagStat(LanraragiTagStat stat) {
    final colonIndex = stat.value.indexOf(':');
    final kind = colonIndex == -1 ? 'tag' : stat.value.substring(0, colonIndex).trim();
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
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white70),
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
  });

  final double width;
  final String label;
  final List<_ToolbarMenuOption<T>> items;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
        menuChildren: items
            .map(
              (item) => MenuItemButton(
                onPressed: () => onSelected(item.value),
                closeOnActivate: true,
                style: ButtonStyle(
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  minimumSize: WidgetStatePropertyAll(Size(width, 36)),
                  maximumSize: WidgetStatePropertyAll(Size(width, 36)),
                  shape: const WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
                      return AppTheme.crimson.withValues(alpha: 0.14);
                    }
                    return const Color(0xFF1E1E1E);
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
                      return AppTheme.textPrimary;
                    }
                    return AppTheme.textSecondary;
                  }),
                  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                ),
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
            )
            .toList(growable: false),
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
                  border: Border.fromBorderSide(BorderSide(color: AppTheme.border, width: 0.5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.expand_more, size: 16, color: AppTheme.textSecondary),
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

class _GroupedTagNamespace {
  const _GroupedTagNamespace({required this.namespace, required this.tags});

  final String namespace;
  final List<String> tags;
}

class _ArchiveDetailsDrawer extends StatelessWidget {
  const _ArchiveDetailsDrawer({
    required this.archive,
    required this.groupedTags,
    required this.onClose,
    required this.onRead,
    required this.onTagSelected,
  });

  final Archive? archive;
  final List<_GroupedTagNamespace> groupedTags;
  final VoidCallback onClose;
  final VoidCallback onRead;
  final ValueChanged<String> onTagSelected;

  String _tagLabel(String namespace, String rawTag) {
    final separatorIndex = rawTag.indexOf(':');
    final value = separatorIndex == -1 ? rawTag.trim() : rawTag.substring(separatorIndex + 1).trim();
    final formattedDate = _tryFormatTagDate(namespace, value);
    if (formattedDate != null) {
      return formattedDate;
    }
    return value;
  }

  String? _tryFormatTagDate(String namespace, String value) {
    final normalizedNamespace = namespace.toLowerCase();
    if (!normalizedNamespace.contains('date') && !normalizedNamespace.contains('time')) {
      return null;
    }

    final epochValue = int.tryParse(value);
    if (epochValue == null) {
      return null;
    }

    final timestamp = epochValue < 1000000000000 ? epochValue * 1000 : epochValue;
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
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: const Color(0xFF666666),
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.18,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      elevation: 24,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: AppTheme.border, width: 0.5),
          ),
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
                    : SelectionArea(
                        child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AspectRatio(
                              aspectRatio: 2 / 3,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: ArchiveThumbnail(archive: archive!, fit: BoxFit.cover),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              archive!.title,
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: AppTheme.textPrimary),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              archive!.pageCount == null ? 'Unknown page count' : '${archive!.pageCount} pages',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                            ),
                            if (archive!.sourceUrl != null && archive!.sourceUrl!.trim().isNotEmpty) ...[
                              const SizedBox(height: 16),
                              _buildSectionLabel(context, 'Source'),
                              const SizedBox(height: 6),
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => _openSourceUrl(archive!.sourceUrl!.trim()),
                                  behavior: HitTestBehavior.opaque,
                                  child: Text(
                                    archive!.sourceUrl!.trim(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: AppTheme.crimson,
                                      decoration: TextDecoration.underline,
                                      decorationColor: AppTheme.crimson,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            for (final namespace in groupedTags) ...[
                              _buildSectionLabel(context, namespace.namespace),
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
                                          style: const TextStyle(fontSize: 11, color: AppTheme.crimson, fontWeight: FontWeight.w500),
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                        visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        backgroundColor: const Color(0xFF2A2A2A),
                                        side: BorderSide.none,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (groupedTags.isEmpty)
                              Text(
                                'No tags available.',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                              ),
                          ],
                        ),
                      ),
                    ),
              ),
              if (archive != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: onRead,
                      style: const ButtonStyle(
                        mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
                      ),
                      child: const Text('Read'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onRefresh,
    this.onOpenSidebarMenu,
  });

  final VoidCallback onRefresh;
  final VoidCallback? onOpenSidebarMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(
          bottom: BorderSide(color: AppTheme.border, width: 0.5),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: DragToMoveArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showSidebarMenuButton = onOpenSidebarMenu != null && constraints.maxWidth < 780;

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
                      onPressed: onRefresh,
                    ),
                    if (_isDesktopWindowControlsEnabled) ...[
                      const SizedBox(width: 8),
                      const _WindowControlButton(
                        glyph: _MinimizeWindowGlyph(),
                        hoverColor: AppTheme.surfaceRaised,
                        onPressed: _minimizeWindow,
                      ),
                      const SizedBox(width: 4),
                      const _MaximizeWindowControlButton(),
                      const SizedBox(width: 4),
                      const _WindowControlButton(
                        icon: Icons.close,
                        hoverColor: Color(0xFFE81123),
                        onPressed: _closeWindow,
                        hoverIconColor: Colors.white,
                      ),
                    ],
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
        border: Border(
          right: BorderSide(color: AppTheme.border, width: 0.5),
        ),
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
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: isPickingRandom
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.casino_outlined, size: 18),
              label: Text(isPickingRandom ? AppStrings.pickingRandom : AppStrings.randomPick),
            ),
          ),
          if (randomPickMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              randomPickMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: randomPickMessageIsError ? AppTheme.crimson : AppTheme.textMuted,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Text(
            AppStrings.onDeckTitle,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.textMuted,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: isLoadingOnDeck
                ? const Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : onDeckEntries.isEmpty
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      onDeckMessage ?? AppStrings.recentInProgressPlaceholder,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onDeckMessageIsError ? AppTheme.crimson : AppTheme.textMuted,
                      ),
                    ),
                  )
                : _Scrollbarless(
                    child: ListView.separated(
                      itemCount: onDeckEntries.length,
                      separatorBuilder: (context, index) => const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(
                          height: 1,
                          thickness: 0.5,
                          color: AppTheme.border,
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final entry = onDeckEntries[index];
                        return _OnDeckCoverTile(
                          entry: entry,
                          onTap: () => onOpenOnDeck(entry),
                        );
                      },
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
            message: isPickingRandom ? AppStrings.pickingRandomTooltip : AppStrings.randomPick,
            child: _SidebarIconButton(
              icon: isPickingRandom ? Icons.hourglass_top : Icons.casino_outlined,
              onTap: isPickingRandom ? null : onRandomPick,
              accent: const Color(0xFF49D7E8),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Column(
              children: [
                if (isLoadingOnDeck)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                for (final entry in onDeckEntries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Tooltip(
                      message: '${entry.title}\n${entry.currentPage} / ${entry.totalPages}',
                      child: _CompactOnDeckThumb(
                        entry: entry,
                        onTap: () => onOpenOnDeck(entry),
                      ),
                    ),
                  ),
              ],
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
        mouseCursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: accent == null ? AppTheme.textSecondary : const Color(0xFF03161A),
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
  const _TopBarIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_TopBarIconButton> createState() => _TopBarIconButtonState();
}

class _TopBarIconButtonState extends State<_TopBarIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
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
          child: Icon(
            widget.icon,
            size: 18,
            color: _hovered ? AppTheme.textPrimary : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    required this.onPressed,
    required this.hoverColor,
    this.icon,
    this.glyph,
    this.hoverIconColor,
  });

  final IconData? icon;
  final Widget? glyph;
  final Future<void> Function() onPressed;
  final Color hoverColor;
  final Color? hoverIconColor;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => widget.onPressed(),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 30,
          height: 28,
          decoration: BoxDecoration(
            color: _hovered ? widget.hoverColor : Colors.transparent,
          ),
          child: Center(
            child: IconTheme(
              data: IconThemeData(
                size: 14,
                color: _hovered
                    ? (widget.hoverIconColor ?? AppTheme.textPrimary)
                    : AppTheme.textSecondary,
              ),
              child: widget.glyph ?? Icon(widget.icon),
            ),
          ),
        ),
      ),
    );
  }
}

class _MaximizeWindowControlButton extends StatefulWidget {
  const _MaximizeWindowControlButton();

  @override
  State<_MaximizeWindowControlButton> createState() =>
      _MaximizeWindowControlButtonState();
}

class _MaximizeWindowControlButtonState
    extends State<_MaximizeWindowControlButton> with WindowListener {
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncWindowState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    _setExpanded(true);
  }

  @override
  void onWindowUnmaximize() {
    _syncWindowState();
  }

  @override
  void onWindowEnterFullScreen() {
    _setExpanded(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _syncWindowState();
  }

  Future<void> _syncWindowState() async {
    final isExpanded = await windowManager.isFullScreen() ||
        await windowManager.isMaximized();
    _setExpanded(isExpanded);
  }

  void _setExpanded(bool value) {
    if (!mounted || _isExpanded == value) {
      return;
    }
    setState(() {
      _isExpanded = value;
    });
  }

  Future<void> _handlePressed() async {
    await _toggleMaximizeWindow();
    await _syncWindowState();
  }

  @override
  Widget build(BuildContext context) {
    return _WindowControlButton(
      icon:
          _isExpanded ? Icons.filter_none_rounded : Icons.check_box_outline_blank_rounded,
      hoverColor: AppTheme.surfaceRaised,
      onPressed: _handlePressed,
    );
  }
}

class _MinimizeWindowGlyph extends StatelessWidget {
  const _MinimizeWindowGlyph();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? AppTheme.textSecondary;

    return Container(
      width: 10,
      height: 1.6,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}


bool get _isDesktopWindowControlsEnabled {
  if (kIsWeb) {
    return false;
  }

  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
    _ => false,
  };
}

Future<void> _minimizeWindow() async {
  await windowManager.minimize();
}

Future<void> _toggleMaximizeWindow() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
    return;
  }
  await windowManager.maximize();
}

Future<void> _closeWindow() async {
  await windowManager.close();
}
