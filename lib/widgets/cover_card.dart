import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/archive.dart';
import '../providers/settings_provider.dart';
import 'theme.dart';

class CoverCard extends StatelessWidget {
  const CoverCard({super.key, required this.archive, this.onTap});

  final Archive archive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isCompleted = archive.isCompleted;
    final pageCount = archive.pageCount;
    final showPageCount = pageCount != null && pageCount > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Opacity(
                  opacity: isCompleted ? 0.4 : 1,
                  child: ArchiveThumbnail(archive: archive),
                ),
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    widthFactor: 1,
                    heightFactor: 0.4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Color(0xFF000000),
                            Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (isCompleted)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xD9101217),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppTheme.border, width: 0.5),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check, size: 12, color: AppTheme.crimson),
                            SizedBox(width: 4),
                            Text(
                              'Read',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (showPageCount)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: DecoratedBox(
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
                    ),
                  ),
                Positioned(
                  left: 8,
                  right: showPageCount ? 40 : 8,
                  bottom: 8,
                  child: Text(
                    archive.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
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
}

class ArchiveThumbnail extends StatelessWidget {
  const ArchiveThumbnail({
    super.key,
    required this.archive,
    this.borderRadius = 6,
    this.fit = BoxFit.cover,
  });

  final Archive archive;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsModel.instance;
    final imageSources = _resolveImageSources(settings.serverUrl, archive);
    final headers = settings.authHeader();

    if (imageSources.isEmpty) {
      return const ColoredBox(color: AppTheme.surfaceRaised);
    }

    return _CoverImage(
      sources: imageSources,
      headers: headers,
      fit: fit,
    );
  }

  static List<_ThumbnailSource> _resolveImageSources(String serverUrl, Archive archive) {
    if (serverUrl.isEmpty || archive.id.isEmpty) {
      return const [];
    }

    final normalizedBase = _normalizeBase(serverUrl);
    final thumbnailUrl = '$normalizedBase/api/archives/${archive.id}/thumbnail';
    final sources = <_ThumbnailSource>[
      _ThumbnailSource(url: thumbnailUrl, cacheKey: 'archive-thumbnail-${archive.id}'),
    ];

    final coverUrl = _resolveCoverUrl(normalizedBase, archive.coverUrl);
    if (coverUrl != null && coverUrl.isNotEmpty && coverUrl != thumbnailUrl) {
      sources.add(_ThumbnailSource(url: coverUrl, cacheKey: 'archive-cover-${archive.id}'));
    }

    return sources;
  }

  static String? _resolveCoverUrl(String normalizedBase, String? rawCoverUrl) {
    final cover = rawCoverUrl?.trim();
    if (cover == null || cover.isEmpty) {
      return null;
    }

    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    if (cover.startsWith('/')) {
      return '$normalizedBase$cover';
    }
    return '$normalizedBase/${cover.replaceFirst(RegExp(r'^/+'), '')}';
  }

  static String _normalizeBase(String value) {
    var normalized = value.trim().replaceAll(RegExp(r',\s*$'), '');
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.toLowerCase().endsWith('/api')) {
      normalized = normalized.substring(0, normalized.length - 4);
    }
    return normalized;
  }
}

class _ThumbnailSource {
  const _ThumbnailSource({required this.url, required this.cacheKey});

  final String url;
  final String cacheKey;
}

class _CoverImage extends StatefulWidget {
  const _CoverImage({required this.sources, required this.headers, required this.fit});

  final List<_ThumbnailSource> sources;
  final Map<String, String> headers;
  final BoxFit fit;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    if (_currentIndex >= widget.sources.length) {
      return const ColoredBox(color: AppTheme.surfaceRaised);
    }

    final source = widget.sources[_currentIndex];
    return CachedNetworkImage(
      key: ValueKey(source.cacheKey),
      imageUrl: source.url,
      cacheKey: source.cacheKey,
      httpHeaders: widget.headers,
      fit: widget.fit,
      alignment: Alignment.topLeft,
      placeholderFadeInDuration: Duration.zero,
      fadeInDuration: Duration.zero,
      placeholder: (context, url) => const ColoredBox(color: AppTheme.surfaceRaised),
      errorWidget: (context, url, error) {
        if (_currentIndex < widget.sources.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            setState(() {
              _currentIndex += 1;
            });
          });
        }
        return const ColoredBox(color: AppTheme.surfaceRaised);
      },
    );
  }
}
