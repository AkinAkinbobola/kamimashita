import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

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
  final Set<String> _ownedIds = <String>{};
  final Set<String> _selectedIds = <String>{};
  final List<_NhentaiSearchItem> _results = <_NhentaiSearchItem>[];

  int _page = 1;
  int _total = 0;
  bool _isLoadingOwned = true;
  bool _isSearching = false;
  bool _isLoadingMore = false;
  bool _isQueueing = false;
  String? _message;

  bool get _hasMore => _results.length < _total;

  @override
  void initState() {
    super.initState();
    unawaited(_loadOwned());
  }

  @override
  void dispose() {
    _queryController.dispose();
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
      _results.clear();
      _selectedIds.clear();
    });

    try {
      final result = await _fetchPage(query, 1);
      if (!mounted) {
        return;
      }
      setState(() {
        _results.addAll(result.results);
        _total = result.total;
      });
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

  Future<void> _loadMore() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _isLoadingMore || !_hasMore) {
      return;
    }

    final nextPage = _page + 1;
    setState(() {
      _isLoadingMore = true;
      _message = null;
    });

    try {
      final result = await _fetchPage(query, nextPage);
      if (!mounted) {
        return;
      }
      setState(() {
        _page = nextPage;
        _results.addAll(result.results);
        _total = result.total;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _message = _cleanError(error));
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  Future<_NhentaiSearchResult> _fetchPage(String query, int page) async {
    final response = await _dio.get<Object>(
      '/search',
      queryParameters: <String, Object>{'query': query, 'page': page},
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
    final ids = _results
        .where((item) => !_ownedIds.contains(item.id))
        .map((item) => item.id)
        .toSet()
        .toList(growable: false);
    return _queueIds(ids);
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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            elevation: 0,
            backgroundColor: const Color(0xFF1A1A1A),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            content: Text(
              '${ids.length} galleries queued',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      Navigator.of(context).pop();
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
                _Header(onClose: () => Navigator.of(context).pop()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _SearchField(
                    controller: _queryController,
                    isLoading: _isSearching,
                    onSearch: _search,
                  ),
                ),
                Expanded(child: _buildBody(theme)),
                _BottomBar(
                  selectedCount: _selectedIds.length,
                  hasQueueableResults: _results.any(
                    (item) => !_ownedIds.contains(item.id),
                  ),
                  isQueueing: _isQueueing,
                  onQueueSelected: _selectedIds.isEmpty ? null : _queueSelected,
                  onQueueAll: _queueAll,
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
          child: hasResults
              ? GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.58,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final item = _results[index];
                    return _ResultCard(
                      item: item,
                      isOwned: _ownedIds.contains(item.id),
                      isSelected: _selectedIds.contains(item.id),
                      onTap: () => _toggleSelection(item),
                    );
                  },
                )
              : Center(
                  child: Text(
                    _isSearching ? 'Searching...' : 'No results yet',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
        ),
        if (_hasMore)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: _TextActionButton(
              label: _isLoadingMore ? 'Loading...' : 'Load more',
              enabled: !_isLoadingMore,
              onTap: _loadMore,
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

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
          _IconActionButton(icon: Icons.close, onTap: onClose),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.isLoading,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool isLoading;
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
          _IconActionButton(
            icon: isLoading ? Icons.hourglass_empty : Icons.search,
            onTap: isLoading ? null : onSearch,
          ),
        ],
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
    final theme = Theme.of(context);
    final selectable = !isOwned;

    return MouseRegion(
      cursor: selectable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: selectable ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? AppTheme.crimson : Colors.transparent,
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              Opacity(
                opacity: isOwned ? 0.4 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(
                              color: AppTheme.surfaceRaised,
                              child: Image.network(
                                item.thumbnailUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                frameBuilder:
                                    (
                                      context,
                                      child,
                                      frame,
                                      wasSynchronouslyLoaded,
                                    ) {
                                      if (wasSynchronouslyLoaded ||
                                          frame != null) {
                                        return child;
                                      }
                                      return const ColoredBox(
                                        color: AppTheme.surfaceRaised,
                                      );
                                    },
                                errorBuilder: (context, error, stackTrace) {
                                  return const ColoredBox(
                                    color: AppTheme.surfaceRaised,
                                  );
                                },
                              ),
                            ),
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: _PageBadge(pageCount: item.numPages),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (isOwned || isSelected)
                const Positioned(
                  top: 9,
                  right: 9,
                  child: _CheckBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckBadge extends StatelessWidget {
  const _CheckBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9101217),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.border, width: 0.5),
      ),
      child: const Padding(
        padding: EdgeInsets.all(5),
        child: Icon(Icons.check, size: 12, color: AppTheme.crimson),
      ),
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.pageCount});

  final int pageCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          '${pageCount}p',
          style: const TextStyle(
            color: AppTheme.crimson,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
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
  });

  final int selectedCount;
  final bool hasQueueableResults;
  final bool isQueueing;
  final VoidCallback? onQueueSelected;
  final VoidCallback onQueueAll;

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
            onTap: onQueueAll,
          ),
        ],
      ),
    );
  }
}

class _IconActionButton extends StatelessWidget {
  const _IconActionButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            icon,
            size: 18,
            color: onTap == null ? AppTheme.textMuted : AppTheme.textSecondary,
          ),
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
              color: enabled ? const Color(0xFF03161A) : const Color(0xFFB4DDE3),
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
  const _NhentaiSearchResult({required this.results, required this.total});

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
    );
  }

  final List<_NhentaiSearchItem> results;
  final int total;
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
