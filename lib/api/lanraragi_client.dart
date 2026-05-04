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
  Future<List<Archive>> listLibrary({int start = -1, int page = 1}) async {
    // Use /api/search with start=-1 to request unpaged data when supported by server.
    try {
      final resp = await _dio.get('/api/search', queryParameters: {'start': start, 'page': page});
      final items = _unwrapList(resp);
      return items.map((e) => Archive.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } on DioError catch (e) {
      throw LanraragiException(e.message);
    }
  }

  /// Search the library using LANraragi's `filter` parameter.
  Future<List<Archive>> search(String query, {int start = 0}) async {
    try {
      final resp = await _dio.get('/api/search', queryParameters: {'filter': query, 'start': start});
      final items = _unwrapList(resp);
      return items.map((e) => Archive.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } on DioError catch (e) {
      throw LanraragiException(e.message);
    }
  }

  /// Get page image URLs for an archive ID. LANraragi usually returns a list of URLs.
  /// Attempts a few common endpoints; returns the first successful list.
  Future<List<String>> getPageUrls(String archiveId) async {
    // Use the canonical endpoint /api/archives/{id}/files as the single source.
    final path = '/api/archives/$archiveId/files';
    try {
      final resp = await _dio.get(path);
      final data = resp.data;
      if (data == null) return [];

      // If the endpoint returns a list of strings
      if (data is List) {
        // List may contain strings or maps
        if (data.isEmpty) return [];
        if (data.first is String) return data.map((e) => e.toString()).toList();
        if (data.first is Map) {
          final List<String> urls = [];
          for (final item in data) {
            if (item is Map) {
              if (item.containsKey('url')) {
                urls.add(item['url'].toString());
                continue;
              }
              if (item.containsKey('name')) {
                final filename = item['name'].toString();
                urls.add(_buildArchiveFileUrl(archiveId, filename));
                continue;
              }
              if (item.containsKey('filename')) {
                final filename = item['filename'].toString();
                urls.add(_buildArchiveFileUrl(archiveId, filename));
                continue;
              }
            }
          }
          if (urls.isNotEmpty) return urls;
        }
      }

      // If the response is a map with a list inside
      if (data is Map) {
        for (final key in ['files', 'data', 'result', 'pages']) {
          if (data.containsKey(key) && data[key] is List) {
            final list = data[key] as List;
            if (list.isEmpty) return [];
            if (list.first is String) return list.map((e) => e.toString()).toList();
            final List<String> urls = [];
            for (final item in list) {
              if (item is String) urls.add(item);
              if (item is Map) {
                if (item.containsKey('url')) urls.add(item['url'].toString());
                else if (item.containsKey('name')) urls.add(_buildArchiveFileUrl(archiveId, item['name'].toString()));
                else if (item.containsKey('filename')) urls.add(_buildArchiveFileUrl(archiveId, item['filename'].toString()));
              }
            }
            if (urls.isNotEmpty) return urls;
          }
        }
      }
    } on DioError catch (e) {
      throw LanraragiException(e.message);
    }

    throw LanraragiException('Failed to fetch page URLs for $archiveId');
  }

  String _buildArchiveFileUrl(String archiveId, String filename) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base/api/archives/$archiveId/files/${Uri.encodeComponent(filename)}';
  }
}

