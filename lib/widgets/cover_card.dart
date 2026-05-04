import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/archive.dart';

class CoverCard extends StatelessWidget {
  const CoverCard({Key? key, required this.archive, this.onTap}) : super(key: key);

  final Archive archive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cover = archive.coverUrl;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 3)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: cover != null && cover.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: cover,
                        fit: BoxFit.cover,
                        placeholder: (c, _) => Container(color: Colors.grey[900]),
                        errorWidget: (c, _, __) => Container(color: Colors.grey[800]),
                      )
                    : Container(color: Colors.grey[850]),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            archive.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (archive.pageCount != null)
            Text('${archive.pageCount} pages', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
