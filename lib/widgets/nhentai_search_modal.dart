import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class NhentaiSearchModal extends StatefulWidget {
  const NhentaiSearchModal({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0xB8000000),
      builder: (_) => const NhentaiSearchModal(),
    );
  }

  @override
  State<NhentaiSearchModal> createState() => _NhentaiSearchModalState();
}

class _NhentaiSearchModalState extends State<NhentaiSearchModal> {
  static const _baseUrl = 'http://127.0.0.1:8765';

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      sendTimeout: const Duration(seconds: 8),
      headers: const {'Content-Type': 'application/json'},
    ),
  );
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _pageInputController = TextEditingController();
  final ScrollController _resultsScrollController = ScrollController();
  final Set<String> _ownedIds = <String>{};
  final Set<String> _selectedIds = <String>{};
  final List<_NhentaiSearchItem> _results = <_NhentaiSearchItem>[];

  String _selectedSort = 'date';
  bool _showOwned = false;
  int _page = 1;
  int _total = 0;
  int _numPages = 0;
  bool _isLoadingOwned = true;
  bool _isSearching = false;
  bool _isQueueing = false;
  String? _message;

  List<_NhentaiSearchItem> get _displayResults => _showOwned
      ? _results
      : _results.where((item) => !_ownedIds.contains(item.id)).toList(growable: false);

  @override
  void initState() {
    super.initState();
    unawaited(_loadOwned());
  }

  @override
  void dispose() {
    _resultsScrollController.dispose();
    _queryController.dispose();
    _pageInputController.dispose();
    super.dispose();
  }

  Future<void> _loadOwned() async {
    try {
      final response = await _dio.get<Object>('/owned');
      final payload = response.data;
      final ids = payload is List
          ? payload.map((value) => value.toString()).toSet()
          : <String>{};
      if (!mounted) {
        return;
      }
      setState(() {
        _ownedIds
          ..clear()
          ..addAll(ids);
        _isLoadingOwned = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingOwned = false;
        _message = _cleanError(error);
      });
    }
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _isSearching) {
      return;
    }

    setState(() {
      _isSearching = true;
      _message = null;
      _page = 1;
      _total = 0;
      _numPages = 0;
      _results.clear();
      _selectedIds.clear();
    });

    try {
      final result = await _fetchPage(query, 1, _selectedSort);
      if (!mounted) {
        return;
      }
      setState(() {
        _results
          ..clear()
          ..addAll(result.results);
        _total = result.total;
        _numPages = result.numPages;
        _page = 1;
        _pageInputController.text = '1';
      });
      _scrollToTop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _message = _cleanError(error));
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _goToPage(int page) async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _isSearching) {
      return;
    }
    final clamped = page.clamp(1, _numPages > 0 ? _numPages : 1);

    setState(() {
      _isSearching = true;
      _message = null;
      _selectedIds.clear();
    });

    try {
      final result = await _fetchPage(query, clamped, _selectedSort);
      if (!mounted) {
        return;
      }
      setState(() {
        _results
          ..clear()
          ..addAll(result.results);
        _total = result.total;
        _numPages = result.numPages;
        _page = clamped;
        _pageInputController.text = clamped.toString();
      });
      _scrollToTop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = _cleanError(error);
        _pageInputController.text = _page.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _scrollToTop() {
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
  }

  Future<_NhentaiSearchResult> _fetchPage(
    String query,
    int page,
    String sort,
  ) async {
    final response = await _dio.get<Object>(
      '/search',
      queryParameters: <String, Object>{
        'query': query,
        'page': page,
        'sort': sort,
      },
    );
    final json = response.data;
    if (json is! Map) {
      throw StateError('Invalid search response');
    }
    return _NhentaiSearchResult.fromJson(json.cast<String, Object?>());
  }

  Future<void> _queueSelected() {
    final selected = _selectedIds.toList(growable: false);
    return _queueIds(selected);
  }

  Future<void> _queueAll() {
    final ids = _displayResults
        .where((item) => !_ownedIds.contains(item.id))
        .map((item) => item.id)
        .toList(growable: false);
    return _queueIds(ids);
  }

  void _selectAll() {
    setState(() {
      for (final item in _displayResults) {
        if (!_ownedIds.contains(item.id)) {
          _selectedIds.add(item.id);
        }
      }
    });
  }

  Future<void> _queueIds(List<String> ids) async {
    if (ids.isEmpty || _isQueueing) {
      return;
    }

    setState(() => _isQueueing = true);
    try {
      await _dio.post<Object>('/queue', data: <String, Object>{'ids': ids});
      if (!mounted) {
        return;
      }
      // Stay in the modal — mark queued items as owned so they grey out,
      // clear the selection, and let the user keep browsing.
      setState(() {
        _ownedIds.addAll(ids);
        _selectedIds.clear();
        _isQueueing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isQueueing = false;
        _message = _cleanError(error);
      });
    }
  }

  void _toggleSelection(_NhentaiSearchItem item) {
    if (_ownedIds.contains(item.id)) {
      return;
    }
    setState(() {
      if (!_selectedIds.add(item.id)) {
        _selectedIds.remove(item.id);
      }
    });
  }

  void _handleSortChanged(String sort) {
    if (sort == _selectedSort) {
      return;
    }
    setState(() => _selectedSort = sort);
    if (_queryController.text.trim().isNotEmpty) {
      unawaited(_search());
    }
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('DioException: ', '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          child: Container(
            color: const Color(0xFF1A1A1A),
            child: Column(
              children: [
                _Header(
                  showOwned: _showOwned,
                  onToggleShowOwned: () =>
                      setState(() => _showOwned = !_showOwned),
                  onClose: () => Navigator.of(context).pop(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SearchField(
                        controller: _queryController,
                        selectedSort: _selectedSort,
                        isLoading: _isSearching,
                        onSortChanged: _handleSortChanged,
                        onSearch: _search,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$_total results',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _buildBody(theme)),
                _BottomBar(
                  selectedCount: _selectedIds.length,
                  hasQueueableResults: _displayResults
                      .any((item) => !_ownedIds.contains(item.id)),
                  isQueueing: _isQueueing,
                  onQueueSelected: _selectedIds.isEmpty ? null : _queueSelected,
                  onQueueAll: _queueAll,
                  onSelectAll: _displayResults.isEmpty ? null : _selectAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoadingOwned) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final display = _displayResults;
    // Use raw _results for hasResults so pagination stays visible even when
    // all items on the current page are hidden by the owned filter.
    final hasResults = _results.isNotEmpty;

    return Column(
      children: [
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _message!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.crimson,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        Expanded(
          child: display.isNotEmpty
              ? GridView.builder(
                  controller: _resultsScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                    childAspectRatio: 3 / 4,
                  ),
                  itemCount: display.length,
                  itemBuilder: (context, index) {
                    final item = display[index];
                    final isOwned = _ownedIds.contains(item.id);
                    return _ResultCard(
                      item: item,
                      isOwned: isOwned,
                      isSelected: _selectedIds.contains(item.id),
                      onTap: () => _toggleSelection(item),
                    );
                  },
                )
              : Center(
                  child: Text(
                    _isSearching
                        ? 'Searching...'
                        : hasResults
                            ? 'All results on this page are owned'
                            : 'No results yet',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
        ),
        if (hasResults && _numPages > 1)
          _PaginationBar(
            currentPage: _page,
            numPages: _numPages,
            isLoading: _isSearching,
            pageInputController: _pageInputController,
            onPrev: _page > 1 ? () => _goToPage(_page - 1) : null,
            onNext: _page < _numPages ? () => _goToPage(_page + 1) : null,
            onJump: (page) => _goToPage(page),
          ),
      ],
    );
  }
}

class _PaginationBar extends StatelessWidget {
  const _PaginationBar({
    required this.currentPage,
    required this.numPages,
    required this.isLoading,
    required this.pageInputController,
    required this.onPrev,
    required this.onNext,
    required this.onJump,
  });

  final int currentPage;
  final int numPages;
  final bool isLoading;
  final TextEditingController pageInputController;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PaginationArrow(
            icon: Icons.chevron_left,
            enabled: onPrev != null && !isLoading,
            onTap: onPrev,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 40,
            height: 26,
            child: TextField(
              controller: pageInputController,
              enabled: !isLoading,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w500,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.go,
              onSubmitted: (value) {
                final page = int.tryParse(value);
                if (page != null && page >= 1) {
                  onJump(page);
                } else {
                  pageInputController.text = currentPage.toString();
                }
              },
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF111014),
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(
                    color: AppTheme.textMuted.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(
                    color: AppTheme.textMuted.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(
                    color: Color(0xFF00E5FF),
                    width: 1,
                  ),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.zero,
                  borderSide: BorderSide(
                    color: AppTheme.textMuted.withOpacity(0.15),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'of $numPages',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textMuted,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(width: 6),
          _PaginationArrow(
            icon: Icons.chevron_right,
            enabled: onNext != null && !isLoading,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _PaginationArrow extends StatelessWidget {
  const _PaginationArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 20,
            color: enabled
                ? const Color(0xFF00E5FF)
                : AppTheme.textMuted.withOpacity(0.35),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.showOwned,
    required this.onToggleShowOwned,
    required this.onClose,
  });

  final bool showOwned;
  final VoidCallback onToggleShowOwned;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
      child: Row(
        children: [
          Text(
            'Search nhentai',
            style: theme.textTheme.titleMedium?.copyWith(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _IconActionButton(
            icon: showOwned ? Icons.visibility : Icons.visibility_off,
            active: showOwned,
            onTap: onToggleShowOwned,
          ),
          _IconActionButton(icon: Icons.close, onTap: onClose),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.selectedSort,
    required this.isLoading,
    required this.onSortChanged,
    required this.onSearch,
  });

  final TextEditingController controller;
  final String selectedSort;
  final bool isLoading;
  final ValueChanged<String> onSortChanged;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        color: Color(0xFF111014),
        border: Border(
          bottom: BorderSide(color: Color(0xFF49D7E8), width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textPrimary,
              ),
              cursorColor: AppTheme.crimson,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
              decoration: InputDecoration(
                hintText: 'artist:inari, tag:big breasts, language:english...',
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.textMuted,
                ),
                filled: true,
                fillColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          _SortDropdown(
            value: selectedSort,
            onChanged: onSortChanged,
          ),
          _IconActionButton(
            icon: isLoading ? Icons.hourglass_empty : Icons.search,
            onTap: isLoading ? null : onSearch,
          ),
        ],
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.value, required this.onChanged});

  static const _options = <String, String>{
    'popular': 'Popular',
    'date': 'Recent',
    'popular-today': 'Today',
    'popular-week': 'This Week',
    'popular-month': 'This Month',
  };

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        dropdownColor: const Color(0xFF1A1A1A),
        iconEnabledColor: AppTheme.textMuted,
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppTheme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
        items: _options.entries
            .map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(growable: false),
        onChanged: (nextValue) {
          if (nextValue != null) {
            onChanged(nextValue);
          }
        },
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.item,
    required this.isOwned,
    required this.isSelected,
    required this.onTap,
  });

  final _NhentaiSearchItem item;
  final bool isOwned;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: isOwned ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: isOwned ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? const Color(0xFF00E5FF) : Colors.transparent,
              width: 2,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                item.thumbnailUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    return child;
                  }
                  return const ColoredBox(color: AppTheme.surfaceRaised);
                },
                errorBuilder: (context, error, stackTrace) {
                  return const ColoredBox(color: AppTheme.surfaceRaised);
                },
              ),
              if (isOwned) const ColoredBox(color: Colors.black45),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black.withOpacity(0.75),
                  padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          height: 1.1,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 4),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${item.numPages}p',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 10,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isOwned)
                const Positioned(top: 5, right: 5, child: _OwnedBadge()),
              if (isSelected)
                const Positioned(
                  top: 5,
                  left: 5,
                  child: _SelectedBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OwnedBadge extends StatelessWidget {
  const _OwnedBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        border: Border.all(color: const Color(0xFF00E5FF), width: 1),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          'Owned',
          style: TextStyle(
            color: Color(0xFF00E5FF),
            fontSize: 9,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Color(0xFF00E5FF)),
        child: Icon(Icons.check, size: 12, color: Colors.black),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.selectedCount,
    required this.hasQueueableResults,
    required this.isQueueing,
    required this.onQueueSelected,
    required this.onQueueAll,
    required this.onSelectAll,
  });

  final int selectedCount;
  final bool hasQueueableResults;
  final bool isQueueing;
  final VoidCallback? onQueueSelected;
  final VoidCallback onQueueAll;
  final VoidCallback? onSelectAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          Text(
            '$selectedCount selected',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),
          _TextActionButton(
            label: 'Select All',
            enabled: onSelectAll != null && !isQueueing,
            onTap: onSelectAll ?? () {},
          ),
          const Spacer(),
          _FilledActionButton(
            label: isQueueing ? 'Queueing...' : 'Queue Selected',
            enabled: onQueueSelected != null && !isQueueing,
            onTap: onQueueSelected,
          ),
          const SizedBox(width: 12),
          _TextActionButton(
            label: 'Queue All',
            enabled: hasQueueableResults && !isQueueing,
            onTap: _queueAllSafe(onQueueAll),
          ),
        ],
      ),
    );
  }

  VoidCallback _queueAllSafe(VoidCallback fn) => fn;
}

class _IconActionButton extends StatelessWidget {
  const _IconActionButton({
    required this.icon,
    required this.onTap,
    this.active,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool? active;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (onTap == null) {
      color = AppTheme.textMuted;
    } else if (active == true) {
      color = const Color(0xFF00E5FF);
    } else {
      color = AppTheme.textSecondary;
    }

    return MouseRegion(
      cursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

class _FilledActionButton extends StatelessWidget {
  const _FilledActionButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: enabled ? AppTheme.crimson : const Color(0xFF2C6670),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: enabled
                  ? const Color(0xFF03161A)
                  : const Color(0xFFB4DDE3),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _TextActionButton extends StatelessWidget {
  const _TextActionButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: enabled ? AppTheme.textSecondary : AppTheme.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _NhentaiSearchResult {
  const _NhentaiSearchResult({
    required this.results,
    required this.total,
    required this.numPages,
  });

  factory _NhentaiSearchResult.fromJson(Map<String, Object?> json) {
    final rawResults = json['results'];
    return _NhentaiSearchResult(
      results: rawResults is List
          ? rawResults
                .whereType<Map>()
                .map(
                  (item) => _NhentaiSearchItem.fromJson(
                    item.cast<String, Object?>(),
                  ),
                )
                .toList(growable: false)
          : const <_NhentaiSearchItem>[],
      total: _readInt(json['total']),
      numPages: _readInt(json['num_pages']),
    );
  }

  final List<_NhentaiSearchItem> results;
  final int total;
  final int numPages;
}

class _NhentaiSearchItem {
  const _NhentaiSearchItem({
    required this.id,
    required this.title,
    required this.thumbnail,
    required this.numPages,
  });

  factory _NhentaiSearchItem.fromJson(Map<String, Object?> json) {
    final id = _readInt(json['id']);
    return _NhentaiSearchItem(
      id: id.toString(),
      title: json['title']?.toString() ?? id.toString(),
      thumbnail: json['thumbnail']?.toString() ?? '',
      numPages: _readInt(json['num_pages']),
    );
  }

  final String id;
  final String title;
  final String thumbnail;
  final int numPages;

  String get thumbnailUrl {
    return Uri.parse(
      '${_NhentaiSearchModalState._baseUrl}/thumbnail',
    ).replace(queryParameters: <String, String>{'path': thumbnail}).toString();
  }
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}