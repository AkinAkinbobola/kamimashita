import 'package:dio/dio.dart';

import '../models/archive.dart';

class LanraragiException implements Exception {
  final String message;
  LanraragiException(this.message);
  @override
  String toString() => 'LanraragiException: $message';
}

/// Minimal Lanraragi HTTP client.
class LanraragiClient {
  final Dio _dio;
  final String baseUrl;
  final String apiKey; // expected base64-encoded string

  LanraragiClient(this.baseUrl, this.apiKey)
      : _dio = Dio(BaseOptions(baseUrl: baseUrl, connectTimeout: 15000, receiveTimeout: 15000)) {
    if (apiKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    }
    _dio.options.headers['Accept'] = 'application/json';
  }

  // Helper to normalize list responses (various endpoints may return array or object)
  List<dynamic> _unwrapList(Response resp) {
    final data = resp.data;
    if (data == null) return [];
    if (data is List) return data;
    if (data is Map) {
      if (data.containsKey('results') && data['results'] is List) return data['results'] as List;
      if (data.containsKey('data') && data['data'] is List) return data['data'] as List;
      // Try to find the first list value
      final firstList = data.values.firstWhere((v) => v is List, orElse: () => null);
      if (firstList is List) return firstList;
    }
    return [];
  }

  /// List library entries. Attempts /api/list by default.
  Future<List<Archive>> listLibrary({int page = 1, int perPage = 50}) async {
    try {
      final resp = await _dio.get('/api/list', queryParameters: {'page': page, 'perPage': perPage});
      final items = _unwrapList(resp);
      return items.map((e) => Archive.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } on DioError catch (e) {
      throw LanraragiException(e.message);
    }
  }

  /// Search the library; best-effort using /api/search?q=...
  Future<List<Archive>> search(String query, {int page = 1}) async {
    try {
      final resp = await _dio.get('/api/search', queryParameters: {'q': query, 'page': page});
      final items = _unwrapList(resp);
      return items.map((e) => Archive.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } on DioError catch (e) {
      throw LanraragiException(e.message);
    }
  }

  /// Get page image URLs for an archive ID. LANraragi usually returns a list of URLs.
  /// Attempts a few common endpoints; returns the first successful list.
  Future<List<String>> getPageUrls(String archiveId) async {
    final candidates = [
      '/api/getpages/$archiveId',
      '/api/getpages', // maybe ?id=archiveId
      '/api/archive/$archiveId/pages',
      '/api/getpaging/$archiveId',
    ];

    for (final path in candidates) {
      try {
        Response resp;
        if (path.endsWith('/getpages') || path.endsWith('/getpages/')) {
          resp = await _dio.get(path, queryParameters: {'id': archiveId});
        } else if (path == '/api/getpages') {
          resp = await _dio.get(path, queryParameters: {'id': archiveId});
        } else {
          resp = await _dio.get(path);
        }
        final data = resp.data;
        if (data == null) continue;
        if (data is List) return data.map((e) => e.toString()).toList();
        if (data is Map) {
          // common shape: { "pages": ["url1","url2"] } or {"data": [...]}
          if (data.containsKey('pages') && data['pages'] is List) return (data['pages'] as List).map((e) => e.toString()).toList();
          if (data.containsKey('data') && data['data'] is List) return (data['data'] as List).map((e) => e.toString()).toList();
          if (data.containsKey('results') && data['results'] is List) return (data['results'] as List).map((e) => e.toString()).toList();
          // If the map values include a list of strings, use it
          for (final v in data.values) {
            if (v is List && v.isNotEmpty && v.first is String) return v.cast<String>();
          }
        }
      } on DioError catch (_) {
        // try next
        continue;
      }
    }
    throw LanraragiException('Failed to fetch page URLs for $archiveId');
  }
}
