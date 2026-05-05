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

class ArchiveThumbnail extends StatelessWidget {
  const ArchiveThumbnail({
    super.key,
    required this.archive,
    this.fit = BoxFit.cover,
  });

  final Archive archive;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsModel.instance;
    final thumbnailUrl = archive.thumbnailUrl(settings.serverUrl);
    if (thumbnailUrl == null) {
      return const ColoredBox(color: AppTheme.surfaceRaised);
    }

    return Image.network(
      thumbnailUrl,
      headers: settings.authHeader(),
      fit: fit,
      alignment: Alignment.topLeft,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return const ColoredBox(color: AppTheme.surfaceRaised);
      },
      errorBuilder: (context, error, stackTrace) {
        return const ColoredBox(color: AppTheme.surfaceRaised);
      },
    );
  }
}
