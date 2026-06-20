import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
// ignore: implementation_imports
import 'package:flutter_mcp_ui_runtime/src/utils/icon_resolver.dart';

import 'package:appplayer_studio/base.dart';

/// Renders one asset entry as a thumbnail. Resolves `material:<name>`,
/// `data:image;base64,...`, `http(s)://...` URLs, and bundle-relative
/// file paths against [bundlePath]. Falls back to a type-mapped icon
/// when the source cannot be decoded.
class AssetThumbnail extends StatelessWidget {
  const AssetThumbnail({
    super.key,
    required this.entry,
    required this.bundlePath,
    required this.size,
  });
  final Map<String, dynamic> entry;
  final String? bundlePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final type = '${entry['type'] ?? ''}';
    final ref = entry['contentRef'];
    final path = entry['path'];
    return SizedBox(
      width: size,
      height: size,
      child: _resolve(c, type, ref, path),
    );
  }

  Widget _resolve(dynamic c, String type, dynamic ref, dynamic path) {
    if (ref is String && ref.startsWith('material:')) {
      return Icon(
        resolveIconData(ref.substring('material:'.length)),
        size: size * 0.7,
        color: c.textPrimary,
      );
    }
    if (ref is String && ref.startsWith('data:image')) {
      try {
        final commaIdx = ref.indexOf(',');
        if (commaIdx > 0) {
          final header = ref.substring(0, commaIdx);
          final payload = ref.substring(commaIdx + 1);
          if (header.contains(';base64')) {
            final bytes = base64Decode(payload);
            return Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _typeIcon(c, type),
            );
          }
        }
      } catch (_) {}
      return _typeIcon(c, type);
    }
    if (ref is String &&
        (ref.startsWith('http://') || ref.startsWith('https://')) &&
        (type == 'image' || type == 'icon')) {
      return Image.network(
        ref,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _typeIcon(c, type),
      );
    }
    if (path is String &&
        path.isNotEmpty &&
        bundlePath != null &&
        (type == 'image' || type == 'icon')) {
      if (path.toLowerCase().endsWith('.svg')) return _typeIcon(c, type);
      final file = File(p.join(bundlePath!, path));
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _typeIcon(c, type),
      );
    }
    return _typeIcon(c, type);
  }

  Widget _typeIcon(dynamic c, String type) {
    IconData icon;
    switch (type) {
      case 'image':
      case 'icon':
        icon = Icons.image_outlined;
        break;
      case 'font':
        icon = Icons.text_fields;
        break;
      case 'audio':
        icon = Icons.audiotrack;
        break;
      case 'video':
        icon = Icons.movie_outlined;
        break;
      case 'json':
      case 'text':
        icon = Icons.description_outlined;
        break;
      case 'template':
        icon = Icons.code;
        break;
      case 'style':
        icon = Icons.palette_outlined;
        break;
      default:
        icon = Icons.insert_drive_file_outlined;
    }
    return Icon(icon, size: size * 0.7, color: c.textSecondary);
  }
}

/// Center pane view shown when the Assets layer is focused. Renders a
/// responsive grid of asset thumbnails so the user can scan the whole
/// asset registry visually; per-item edit lives in the right panel.
class AssetGalleryView extends StatelessWidget {
  const AssetGalleryView({
    super.key,
    required this.assets,
    required this.bundlePath,
  });
  final AssetSlice assets;
  final String? bundlePath;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final entries = assets.entries;
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              VibeTokens.space4,
              VibeTokens.space4,
              VibeTokens.space4,
              VibeTokens.space2,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.collections_outlined,
                  size: 18,
                  color: c.textSecondary,
                ),
                const SizedBox(width: VibeTokens.space2),
                Text(
                  'Assets · ${entries.length}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  'Edit on the right panel →',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.borderDefault),
          Expanded(
            child:
                entries.isEmpty
                    ? _empty(context, c)
                    : LayoutBuilder(
                      builder: (context, cons) {
                        const tile = 132.0;
                        final cross =
                            (cons.maxWidth ~/ tile).clamp(2, 8).toInt();
                        return GridView.builder(
                          padding: const EdgeInsets.all(VibeTokens.space4),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cross,
                                mainAxisSpacing: VibeTokens.space3,
                                crossAxisSpacing: VibeTokens.space3,
                                childAspectRatio: 0.82,
                              ),
                          itemCount: entries.length,
                          itemBuilder:
                              (_, i) => _Tile(
                                entry: entries[i],
                                bundlePath: bundlePath,
                              ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, dynamic c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.collections_outlined, size: 40, color: c.textSecondary),
          const SizedBox(height: VibeTokens.space3),
          Text(
            'No assets yet',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: VibeTokens.space1),
          Text(
            'Use the right panel to add or import assets.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.entry, required this.bundlePath});
  final Map<String, dynamic> entry;
  final String? bundlePath;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final id = '${entry['id'] ?? ''}';
    final type = '${entry['type'] ?? ''}';
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(VibeTokens.space3),
              child: Center(
                child: AssetThumbnail(
                  entry: entry,
                  bundlePath: bundlePath,
                  size: 72,
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space2,
              vertical: VibeTokens.space2,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.borderDefault)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  type,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
