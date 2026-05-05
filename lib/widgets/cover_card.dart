import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/archive.dart';
import '../providers/library_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/archive_thumbnail_url.dart';
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
                          colors: [Color(0xFF000000), Color(0x00000000)],
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
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check,
                              size: 12,
                              color: AppTheme.crimson,
                            ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
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

class ArchiveThumbnail extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = SettingsModel.instance;
    final libraryState = ref.watch(libraryStateProvider);
    final imageSources = libraryState.resolveArchiveImageSources(
      settings.serverUrl,
      archive,
    );
    final headers = settings.authHeader();

    if (imageSources.isEmpty) {
      return const ColoredBox(color: AppTheme.surfaceRaised);
    }

    return _CoverImage(
      archiveId: archive.id,
      sources: imageSources,
      headers: headers,
      fit: fit,
    );
  }
}

class _CoverImage extends ConsumerStatefulWidget {
  const _CoverImage({
    required this.archiveId,
    required this.sources,
    required this.headers,
    required this.fit,
  });

  final String archiveId;
  final List<ArchiveImageSource> sources;
  final Map<String, String> headers;
  final BoxFit fit;

  @override
  ConsumerState<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<_CoverImage> {
  int _currentIndex = 0;

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final sourcesChanged =
        widget.sources.length != oldWidget.sources.length ||
        !listEquals(
          widget.sources
              .map((source) => source.cacheKey)
              .toList(growable: false),
          oldWidget.sources
              .map((source) => source.cacheKey)
              .toList(growable: false),
        );

    if (sourcesChanged) {
      _currentIndex = 0;
      return;
    }

    if (_currentIndex >= widget.sources.length) {
      _currentIndex = widget.sources.isEmpty ? 0 : widget.sources.length - 1;
    }
  }

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
      imageBuilder: (context, imageProvider) {
        ref.read(libraryStateProvider).clearThumbnailMissing(widget.archiveId);
        return DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: imageProvider,
              fit: widget.fit,
              alignment: Alignment.topLeft,
            ),
          ),
        );
      },
      placeholder: (context, url) =>
          const ColoredBox(color: AppTheme.surfaceRaised),
      errorWidget: (context, url, error) {
        if (_currentIndex >= widget.sources.length - 1) {
          ref.read(libraryStateProvider).markThumbnailMissing(widget.archiveId);
        }
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
