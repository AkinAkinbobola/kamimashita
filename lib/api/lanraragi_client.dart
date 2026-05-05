import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/archive.dart';

/// Exception thrown when a LANraragi request fails with a user-facing message.
class LanraragiException implements Exception {
  final String message;
  LanraragiException(this.message);
  @override
  String toString() => 'LanraragiException: $message';
}

/// Weighted LANraragi tag statistic returned by `/api/database/stats`.
class LanraragiTagStat {
  const LanraragiTagStat({required this.value, required this.weight});

  factory LanraragiTagStat.fromJson(Map<String, dynamic> json) {
    final namespace = json['namespace']?.toString().trim();
    final text = json['text']?.toString().trim() ?? '';
    final formatted = namespace == null || namespace.isEmpty
        ? text
        : '$namespace:$text';
    final rawWeight = json['weight'];
    final weight = rawWeight is int
        ? rawWeight
        : int.tryParse(rawWeight?.toString() ?? '') ?? 0;
    return LanraragiTagStat(value: formatted, weight: weight);
  }

  final String value;
  final int weight;
}

/// Paginated archive result set returned by the LANraragi search API.
class ArchivePage {
  const ArchivePage({
    required this.items,
    required this.start,
    required this.nextStart,
    required this.hasMore,
    this.recordsTotal,
    this.recordsFiltered,
  });

  final List<Archive> items;
  final int? recordsTotal;
  final int? recordsFiltered;
  final int start;
  final int nextStart;
  final bool hasMore;
}

/// Search and filter options supported by the LANraragi search endpoint.
class ArchiveSearchOptions {
  const ArchiveSearchOptions({
    this.categoryId,
    this.sortBy,
    this.order,
    this.newOnly = false,
    this.untaggedOnly = false,
    this.hideCompleted = false,
    this.groupByTanks = false,
  });

  final String? categoryId;
  final String? sortBy;
  final String? order;
  final bool newOnly;
  final bool untaggedOnly;
  final bool hideCompleted;
  final bool groupByTanks;

  /// Converts the search options into LANraragi query parameters.
  Map<String, dynamic> toQueryParameters() {
    return {
      if (categoryId != null && categoryId!.trim().isNotEmpty)
        'category': categoryId,
      if (sortBy != null && sortBy!.trim().isNotEmpty) 'sortby': sortBy,
      if (order != null && order!.trim().isNotEmpty) 'order': order,
      if (newOnly) 'newonly': true,
      if (untaggedOnly) 'untaggedonly': true,
      if (hideCompleted) 'hidecompleted': true,
      if (groupByTanks) 'groupby_tanks': true,
    };
  }
}

/// Category metadata returned by the LANraragi categories endpoint.
class LanraragiCategory {
  const LanraragiCategory({
    required this.id,
    required this.name,
    required this.pinned,
    this.search = '',
    this.archives = const [],
  });

  factory LanraragiCategory.fromJson(Map<String, dynamic> json) {
    final rawPinned = json['pinned'];
    final pinned = rawPinned is int
        ? rawPinned != 0
        : rawPinned is bool
        ? rawPinned
        : rawPinned?.toString() == '1' ||
              rawPinned?.toString().toLowerCase() == 'true';
    final search = json['search']?.toString() ?? '';
    final archives =
        (json['archives'] as List?)
            ?.map((entry) => entry?.toString() ?? '')
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];

    return LanraragiCategory(
      id: json['id']?.toString() ?? json['catid']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      pinned: pinned,
      search: search,
      archives: archives,
    );
  }

  final String id;
  final String name;
  final bool pinned;
  final String search;
  final List<String> archives;

  bool get isDynamic => search.trim().isNotEmpty;
  bool get isStatic => !isDynamic;
}

/// Service wrapper for all LANraragi API calls used by the app.
class LanraragiClient {
  final Dio _dio;
  final String baseUrl;
  final String apiKey; // expected base64-encoded string

  LanraragiClient(String baseUrl, this.apiKey)
    : baseUrl = _normalizeBaseUrl(baseUrl),
      _dio = Dio(
        BaseOptions(
          baseUrl: _normalizeBaseUrl(baseUrl),
          connectTimeout: Duration(milliseconds: 15000),
          receiveTimeout: Duration(milliseconds: 15000),
        ),
      ) {
    if (apiKey.isNotEmpty) {
      _dio.options.headers.addAll(authorizationHeaders(apiKey));
    }
    _dio.options.headers['Accept'] = 'application/json';
  }

  Map<String, Object?> get _authHeaders => authorizationHeaders(apiKey);

  String get _encodedApiKey => base64Encode(utf8.encode(apiKey));

  bool get _canRetryWithEncodedKey =>
      apiKey.isNotEmpty && _encodedApiKey != apiKey;

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.toLowerCase().endsWith('/api')) {
      normalized = normalized.substring(0, normalized.length - 4);
    }
    return normalized;
  }

  /// Normalizes a raw or encoded LANraragi API key for Authorization headers.
  static String normalizeApiKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return normalized;
    }
    if (_looksBase64Encoded(normalized)) {
      return normalized;
    }
    return base64Encode(utf8.encode(normalized));
  }

  /// Builds the Authorization header used for authenticated LANraragi requests.
  static Map<String, String> authorizationHeaders(String apiKey) {
    final normalizedApiKey = normalizeApiKey(apiKey);
    if (normalizedApiKey.isEmpty) {
      return const {};
    }
    return {'Authorization': 'Bearer $normalizedApiKey'};
  }

  static bool _looksBase64Encoded(String value) {
    try {
      final decoded = base64Decode(value);
      final reencoded = base64Encode(decoded);
      return value == reencoded || value == reencoded.replaceAll('=', '');
    } catch (_) {
      return false;
    }
  }

  Future<Response<dynamic>> _get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      return await _dio.get(
        path,
        queryParameters: queryParameters,
        options: Options(headers: _authHeaders),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && _canRetryWithEncodedKey) {
        return _dio.get(
          path,
          queryParameters: queryParameters,
          options: Options(
            headers: {'Authorization': 'Bearer $_encodedApiKey'},
          ),
        );
      }
      rethrow;
    }
  }

  Future<Response<dynamic>> _put(
    String path, {
    dynamic data,
    String? contentType,
  }) async {
    try {
      return await _dio.put(
        path,
        data: data,
        options: Options(headers: _authHeaders, contentType: contentType),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && _canRetryWithEncodedKey) {
        return _dio.put(
          path,
          data: data,
          options: Options(
            headers: {'Authorization': 'Bearer $_encodedApiKey'},
            contentType: contentType,
          ),
        );
      }
      rethrow;
    }
  }

  Future<Response<dynamic>> _delete(String path) async {
    try {
      return await _dio.delete(path, options: Options(headers: _authHeaders));
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && _canRetryWithEncodedKey) {
        return _dio.delete(
          path,
          options: Options(
            headers: {'Authorization': 'Bearer $_encodedApiKey'},
          ),
        );
      }
      rethrow;
    }
  }

  /// Fetches LANraragi server metadata from `/api/info`.
  Future<Map<String, dynamic>> getServerInfo() async {
    try {
      final resp = await _get('/api/info');
      final data = resp.data;
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      throw LanraragiException('Unexpected response from /api/info');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  String _describeRequestFailure(DioException e) {
    final statusCode = e.response?.statusCode;
    if (statusCode == 401) {
      return 'Authentication failed. Check the API key.';
    }
    if (statusCode == 404) {
      return 'Server endpoint not found. Check the server URL.';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return 'Connection timed out. Check the server URL and network.';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Unable to reach the server. Check the server URL and network.';
    }
    final serverMessage = e.response?.data;
    if (serverMessage is Map && serverMessage['error'] != null) {
      return serverMessage['error'].toString();
    }
    return e.message ?? e.toString();
  }

  // Helper to normalize list responses (various endpoints may return array or object)
  List<dynamic> _unwrapList(Response resp) {
    final data = resp.data;
    if (data == null) {
      return [];
    }
    if (data is List) {
      return data;
    }
    if (data is Map) {
      if (data.containsKey('results') && data['results'] is List) {
        return data['results'] as List;
      }
      if (data.containsKey('data') && data['data'] is List) {
        return data['data'] as List;
      }
      // Try to find the first list value
      final firstList = data.values.firstWhere(
        (v) => v is List,
        orElse: () => null,
      );
      if (firstList is List) {
        return firstList;
      }
    }
    return [];
  }

  int? _unwrapCount(Response resp, String key) {
    final data = resp.data;
    if (data is Map) {
      final value = data[key];
      if (value is int) {
        return value;
      }
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  /// Fetches a paginated archive page from `/api/search`.
  Future<ArchivePage> fetchArchivePage({
    String filter = '',
    int start = 0,
    ArchiveSearchOptions options = const ArchiveSearchOptions(),
  }) async {
    try {
      final resp = await _get(
        '/api/search',
        queryParameters: {
          'filter': filter,
          'start': start,
          ...options.toQueryParameters(),
        },
      );
      final rawItems = _unwrapList(resp);
      final items = rawItems
          .whereType<Map>()
          .map((entry) => Archive.fromJson(Map<String, dynamic>.from(entry)))
          .toList(growable: false);
      final recordsTotal =
          _unwrapCount(resp, 'recordsTotal') ?? _unwrapCount(resp, 'total');
      final recordsFiltered =
          _unwrapCount(resp, 'recordsFiltered') ?? recordsTotal;
      final nextStart = start + items.length;
      final hasMore = recordsFiltered != null
          ? nextStart < recordsFiltered
          : items.isNotEmpty;
      return ArchivePage(
        items: items,
        recordsTotal: recordsTotal,
        recordsFiltered: recordsFiltered,
        start: start,
        nextStart: nextStart,
        hasMore: hasMore,
      );
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches all LANraragi categories and returns them in sidebar-friendly
  /// order.
  Future<List<LanraragiCategory>> getCategories() async {
    try {
      final resp = await _get('/api/categories');
      final rawItems = _unwrapList(resp);
      final items = rawItems
          .whereType<Map>()
          .map(
            (entry) =>
                LanraragiCategory.fromJson(Map<String, dynamic>.from(entry)),
          )
          .where(
            (category) => category.id.isNotEmpty && category.name.isNotEmpty,
          )
          .toList(growable: true);
      items.sort((a, b) {
        if (a.pinned != b.pinned) {
          return a.pinned ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return List.unmodifiable(items);
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Creates a category and returns the created category ID.
  Future<String> createCategory({
    required String name,
    String? search,
    bool pinned = false,
  }) async {
    final trimmedName = name.trim();
    final trimmedSearch = search?.trim() ?? '';
    try {
      final resp = await _put(
        '/api/categories',
        data: {
          'name': trimmedName,
          if (trimmedSearch.isNotEmpty) 'search': trimmedSearch,
          if (pinned) 'pinned': true,
        },
        contentType: Headers.formUrlEncodedContentType,
      );
      final data = resp.data;
      if (data is Map) {
        final categoryId = data['category_id']?.toString() ?? '';
        if (categoryId.isNotEmpty) {
          return categoryId;
        }
      }
      throw LanraragiException('Unexpected response from category creation.');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Updates an existing category.
  Future<void> updateCategory({
    required String categoryId,
    required String name,
    String? search,
    bool pinned = false,
  }) async {
    final trimmedName = name.trim();
    final trimmedSearch = search?.trim() ?? '';
    try {
      await _put(
        '/api/categories/$categoryId',
        data: {
          'name': trimmedName,
          'search': trimmedSearch,
          'pinned': pinned ? '1' : '0',
        },
        contentType: Headers.formUrlEncodedContentType,
      );
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Deletes an existing category.
  Future<void> deleteCategory(String categoryId) async {
    try {
      await _delete('/api/categories/$categoryId');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Loads the static categories containing the specified archive.
  Future<List<LanraragiCategory>> getArchiveCategories(String archiveId) async {
    try {
      final resp = await _get('/api/archives/$archiveId/categories');
      final data = resp.data;
      final rawItems = data is Map && data['categories'] is List
          ? data['categories'] as List
          : _unwrapList(resp);
      return rawItems
          .whereType<Map>()
          .map(
            (entry) =>
                LanraragiCategory.fromJson(Map<String, dynamic>.from(entry)),
          )
          .where(
            (category) => category.id.isNotEmpty && category.name.isNotEmpty,
          )
          .toList(growable: false);
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Adds an archive to a static category.
  Future<void> addArchiveToCategory(String categoryId, String archiveId) async {
    try {
      await _put('/api/categories/$categoryId/$archiveId');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Removes an archive from a static category.
  Future<void> removeArchiveFromCategory(
    String categoryId,
    String archiveId,
  ) async {
    try {
      await _delete('/api/categories/$categoryId/$archiveId');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches recent in-progress archives for the On Deck sidebar.
  Future<List<Archive>> getOnDeckArchives() async {
    try {
      final page = await fetchArchivePage(
        start: 0,
        options: const ArchiveSearchOptions(
          sortBy: 'lastread',
          hideCompleted: true,
        ),
      );
      return page.items;
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches a single random archive from the LANraragi random search API.
  Future<Archive?> getRandomArchive() async {
    try {
      final resp = await _get(
        '/api/search/random',
        queryParameters: {'count': 1},
      );
      final rawItems = _unwrapList(resp);
      if (rawItems.isNotEmpty) {
        final first = rawItems.first;
        if (first is Map) {
          return Archive.fromJson(Map<String, dynamic>.from(first));
        }
      }

      final data = resp.data;
      if (data is Map) {
        final candidate = data['data'] ?? data['result'] ?? data['archive'];
        if (candidate is Map) {
          return Archive.fromJson(Map<String, dynamic>.from(candidate));
        }
      }

      return null;
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Search the library using LANraragi's `filter` parameter.
  Future<List<Archive>> search(String query, {int start = 0}) async {
    try {
      return (await fetchArchivePage(filter: query, start: start)).items;
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches full archive metadata for a single archive ID.
  Future<Archive> getArchive(String archiveId) async {
    try {
      final resp = await _get('/api/archives/$archiveId');
      final data = resp.data;
      if (data is Map<String, dynamic>) {
        return Archive.fromJson(data);
      }
      if (data is Map) {
        return Archive.fromJson(Map<String, dynamic>.from(data));
      }
      throw LanraragiException('Unexpected response for archive $archiveId');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches weighted tag statistics for search suggestions.
  Future<List<LanraragiTagStat>> getTagStats() async {
    try {
      final resp = await _get(
        '/api/database/stats',
        queryParameters: {'minweight': 2, 'hide_excluded_namespaces': 'true'},
      );
      final data = resp.data;
      if (data is List) {
        return data
            .whereType<Map>()
            .map(
              (entry) =>
                  LanraragiTagStat.fromJson(Map<String, dynamic>.from(entry)),
            )
            .where((entry) => entry.value.isNotEmpty)
            .toList(growable: false);
      }
      throw LanraragiException('Unexpected response from /api/database/stats');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Fetches the current total archive count from `/api/database/stats`.
  Future<int?> getArchiveCount() async {
    try {
      final resp = await _get('/api/database/stats');
      final data = resp.data;
      return _extractArchiveCount(data);
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Updates LANraragi server-side reading progress for an archive.
  Future<void> updateArchiveProgress(String archiveId, int page) async {
    try {
      await _put('/api/archives/$archiveId/progress/$page');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Clears the LANraragi `isnew` flag for an archive.
  Future<void> clearArchiveIsNew(String archiveId) async {
    try {
      await _delete('/api/archives/$archiveId/isnew');
    } on DioException catch (e) {
      throw LanraragiException(_describeRequestFailure(e));
    }
  }

  /// Get page image URLs for an archive ID.
  /// Prefer OPDS page URLs when a page count is known, since that endpoint is stable across servers.
  Future<List<String>> getPageUrls(
    String archiveId, {
    int? expectedPageCount,
  }) async {
    if (expectedPageCount != null && expectedPageCount > 0) {
      return _buildOpdsPageUrls(archiveId, expectedPageCount);
    }

    final path = '/api/archives/$archiveId/files';
    try {
      final resp = await _get(path);
      final urls = _extractPageUrls(archiveId, resp.data);
      if (urls.isNotEmpty) {
        return urls;
      }
    } on DioException catch (e) {
      if (expectedPageCount == null || expectedPageCount <= 0) {
        throw LanraragiException(_describeRequestFailure(e));
      }
    }

    if (expectedPageCount != null && expectedPageCount > 0) {
      return _buildOpdsPageUrls(archiveId, expectedPageCount);
    }

    throw LanraragiException('Failed to fetch page URLs for $archiveId');
  }

  List<String> _extractPageUrls(String archiveId, dynamic data) {
    if (data == null) {
      return const [];
    }

    if (data is List) {
      return _extractPageUrlsFromList(archiveId, data);
    }

    if (data is Map) {
      for (final key in ['files', 'data', 'result', 'pages']) {
        final value = data[key];
        if (value is List) {
          final urls = _extractPageUrlsFromList(archiveId, value);
          if (urls.isNotEmpty) {
            return urls;
          }
        }
      }
    }

    return const [];
  }

  List<String> _extractPageUrlsFromList(String archiveId, List items) {
    if (items.isEmpty) {
      return const [];
    }

    final urls = <String>[];
    for (final item in items) {
      if (item is String) {
        urls.add(_normalizePageUrl(archiveId, item));
        continue;
      }
      if (item is Map) {
        if (item.containsKey('url')) {
          urls.add(_normalizePageUrl(archiveId, item['url'].toString()));
        } else if (item.containsKey('name')) {
          urls.add(_buildArchiveFileUrl(archiveId, item['name'].toString()));
        } else if (item.containsKey('filename')) {
          urls.add(
            _buildArchiveFileUrl(archiveId, item['filename'].toString()),
          );
        }
      }
    }
    return urls;
  }

  List<String> _buildOpdsPageUrls(String archiveId, int pageCount) {
    return List<String>.generate(
      pageCount,
      (index) => '$baseUrl/api/opds/$archiveId/pse?page=${index + 1}',
    );
  }

  String _normalizePageUrl(String archiveId, String value) {
    final normalized = value.trim();
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return normalized;
    }
    if (normalized.startsWith('/')) {
      return '$baseUrl$normalized';
    }
    return _buildArchiveFileUrl(archiveId, normalized);
  }

  String _buildArchiveFileUrl(String archiveId, String filename) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$base/api/archives/$archiveId/files/${Uri.encodeComponent(filename)}';
  }

  int? _extractArchiveCount(dynamic data) {
    if (data is Map) {
      for (final key in const [
        'archives_per_page',
        'archive_count',
        'archives',
        'recordsTotal',
        'total',
        'count',
      ]) {
        final count = _parseIntValue(data[key]);
        if (count != null) {
          return count;
        }
      }

      for (final key in const ['data', 'stats', 'result']) {
        final nested = _extractArchiveCount(data[key]);
        if (nested != null) {
          return nested;
        }
      }
    }

    return _parseIntValue(data);
  }

  int? _parseIntValue(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
