// Asset pipeline UI — browses / adds / deletes files under
// `<bundle>/assets/`. The mcp_ui DSL bundle layout reserves
// `<bundle>/assets/<path>` for binary blobs (images, fonts, icons,
// other static media). They live outside the canonical JSON tree:
// add / delete operations write directly to the file system rather
// than going through the patch pipeline. The trade-off is that
// asset edits are not part of undo / save — they're committed at
// the moment the user picks them.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:appplayer_studio/base.dart';

/// One file under `<bundle>/assets/`. Captures everything the dialog
/// needs to render a row + offer copy/delete actions.
class _AssetEntry {
  _AssetEntry({
    required this.relativePath,
    required this.absolutePath,
    required this.bytes,
    required this.modified,
  });

  /// Path relative to the bundle's `assets/` directory, with forward
  /// slashes (so the same string is the bundle's canonical asset id).
  final String relativePath;
  final String absolutePath;
  final int bytes;
  final DateTime modified;

  /// Bundle-canonical URI shown in the dialog and copied via the
  /// row's clipboard button — `ui://assets/<path>` lines up with the
  /// existing `ui://app` / `ui://pages/<id>` namespace consumed by
  /// runtime page loaders.
  String get uri => 'ui://assets/$relativePath';

  /// Coarse type bucket used for the leading icon. We don't try to
  /// validate the format — the extension is a hint for the user.
  _AssetKind get kind {
    final ext = p.extension(relativePath).toLowerCase();
    if (const <String>[
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.gif',
      '.bmp',
    ].contains(ext)) {
      return _AssetKind.image;
    }
    if (const <String>['.svg', '.ico'].contains(ext)) {
      return _AssetKind.icon;
    }
    if (const <String>['.ttf', '.otf', '.woff', '.woff2'].contains(ext)) {
      return _AssetKind.font;
    }
    if (const <String>['.mp3', '.wav', '.ogg', '.m4a'].contains(ext)) {
      return _AssetKind.audio;
    }
    if (const <String>['.mp4', '.mov', '.webm', '.mkv'].contains(ext)) {
      return _AssetKind.video;
    }
    return _AssetKind.other;
  }

  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

enum _AssetKind { image, icon, font, audio, video, other }

extension on _AssetKind {
  IconData get icon {
    switch (this) {
      case _AssetKind.image:
        return Icons.image_outlined;
      case _AssetKind.icon:
        return Icons.emoji_symbols_outlined;
      case _AssetKind.font:
        return Icons.text_fields_outlined;
      case _AssetKind.audio:
        return Icons.audiotrack_outlined;
      case _AssetKind.video:
        return Icons.movie_outlined;
      case _AssetKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// Open the assets management modal for the given channel bundle.
/// Returns once the user closes it; the dialog mutates the file
/// system directly, so callers don't need a return value.
Future<void> showAssetsDialog({
  required BuildContext context,
  required String bundlePath,
  required String channelLabel,
}) {
  return showDialog<void>(
    context: context,
    builder:
        (ctx) =>
            _AssetsDialog(bundlePath: bundlePath, channelLabel: channelLabel),
  );
}

class _AssetsDialog extends StatefulWidget {
  const _AssetsDialog({required this.bundlePath, required this.channelLabel});
  final String bundlePath;
  final String channelLabel;

  @override
  State<_AssetsDialog> createState() => _AssetsDialogState();
}

class _AssetsDialogState extends State<_AssetsDialog> {
  List<_AssetEntry> _entries = const <_AssetEntry>[];
  String? _busy;
  String? _selected;

  String get _assetsRoot => p.join(widget.bundlePath, 'assets');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final root = Directory(_assetsRoot);
    final out = <_AssetEntry>[];
    if (await root.exists()) {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        final rel = p
            .relative(entity.path, from: root.path)
            .replaceAll(Platform.pathSeparator, '/');
        out.add(
          _AssetEntry(
            relativePath: rel,
            absolutePath: entity.path,
            bytes: stat.size,
            modified: stat.modified,
          ),
        );
      }
      out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    }
    if (!mounted) return;
    setState(() => _entries = out);
  }

  /// File-pick + copy into `<bundle>/assets/<basename>`. Collisions
  /// auto-rename with a numeric suffix so the source file name stays
  /// the canonical asset id.
  Future<void> _addAsset() async {
    final pick = await FilePicker.platform.pickFiles(
      dialogTitle: 'Add asset',
      allowMultiple: true,
    );
    if (pick == null || pick.files.isEmpty) return;
    setState(() => _busy = 'add');
    try {
      final root = Directory(_assetsRoot);
      if (!await root.exists()) await root.create(recursive: true);
      for (final file in pick.files) {
        final src = file.path;
        if (src == null) continue;
        final base = p.basename(src);
        var dest = p.join(root.path, base);
        var i = 1;
        while (await File(dest).exists()) {
          final stem = p.basenameWithoutExtension(base);
          final ext = p.extension(base);
          dest = p.join(root.path, '$stem-$i$ext');
          i++;
        }
        await File(src).copy(dest);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    await _refresh();
  }

  /// Delete the currently-selected asset. No undo — assets aren't in
  /// the canonical so the patch pipeline can't roll this back.
  Future<void> _deleteSelected() async {
    final id = _selected;
    if (id == null) return;
    final entry = _entries.firstWhere(
      (e) => e.relativePath == id,
      orElse:
          () => _AssetEntry(
            relativePath: '',
            absolutePath: '',
            bytes: 0,
            modified: DateTime.now(),
          ),
    );
    if (entry.absolutePath.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete asset?'),
            content: Text(entry.relativePath),
            actions: <Widget>[
              inspectTag(
                type: 'dialog_action',
                id: 'assets.delete.cancel',
                label: 'Cancel',
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              inspectTag(
                type: 'dialog_action',
                id: 'assets.delete.confirm',
                label: 'Delete',
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Delete'),
                ),
              ),
            ],
          ),
    );
    if (ok != true) return;
    setState(() => _busy = 'delete');
    try {
      await File(entry.absolutePath).delete();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    await _refresh();
  }

  Future<void> _copyUri(_AssetEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.uri));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copied ${entry.uri}',
          style: const TextStyle(fontSize: 12),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Dialog(
      backgroundColor: c.surface2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          children: <Widget>[
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space4,
                VibeTokens.space4,
                VibeTokens.space4,
                VibeTokens.space2,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    'Assets — ${widget.channelLabel}',
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  Text(
                    '${_entries.length} file${_entries.length == 1 ? '' : 's'}',
                    style: vibeMono(size: 10, color: c.textTertiary),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Add files…',
                    onPressed: _busy != null ? null : _addAsset,
                    icon: const Icon(Icons.add, size: 18),
                  ),
                  IconButton(
                    tooltip:
                        _selected == null
                            ? 'Select an asset to delete'
                            : 'Delete selected',
                    onPressed:
                        _busy != null || _selected == null
                            ? null
                            : _deleteSelected,
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _busy != null ? null : _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
            ),
            Divider(color: c.borderSubtle, height: 1),
            // Body — file list.
            Expanded(
              child:
                  _entries.isEmpty
                      ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.folder_open_outlined,
                              size: 32,
                              color: c.textTertiary,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'No assets yet',
                              style: vibeMono(size: 11, color: c.textTertiary),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Tap + to add images, fonts, icons, …',
                              style: vibeMono(size: 10, color: c.textTertiary),
                            ),
                          ],
                        ),
                      )
                      : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (ctx, i) {
                          final e = _entries[i];
                          return _AssetRow(
                            entry: e,
                            selected: e.relativePath == _selected,
                            onSelect:
                                () =>
                                    setState(() => _selected = e.relativePath),
                            onCopyUri: () => _copyUri(e),
                          );
                        },
                      ),
            ),
            Divider(color: c.borderSubtle, height: 1),
            // Footer.
            Padding(
              padding: const EdgeInsets.all(VibeTokens.space3),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Asset edits are committed immediately — '
                      'they are NOT part of Save / Undo.',
                      style: vibeMono(size: 10, color: c.textTertiary),
                    ),
                  ),
                  inspectTag(
                    type: 'dialog_action',
                    id: 'assets.close',
                    label: 'Close',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.entry,
    required this.selected,
    required this.onSelect,
    required this.onCopyUri,
  });
  final _AssetEntry entry;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onCopyUri;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Material(
      color: selected ? c.mint.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space3,
            vertical: 6,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                entry.kind.icon,
                size: 16,
                color: selected ? c.mint : c.textSecondary,
              ),
              const SizedBox(width: VibeTokens.space2),
              Expanded(
                flex: 3,
                child: Text(
                  entry.relativePath,
                  style: vibeMono(
                    size: 11,
                    color: c.textPrimary,
                    weight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: VibeTokens.space2),
              Expanded(
                flex: 4,
                child: Text(
                  entry.uri,
                  style: vibeMono(size: 10, color: c.textTertiary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: VibeTokens.space2),
              SizedBox(
                width: 72,
                child: Text(
                  entry.sizeLabel,
                  style: vibeMono(size: 10, color: c.textTertiary),
                  textAlign: TextAlign.right,
                ),
              ),
              IconButton(
                tooltip: 'Copy URI',
                onPressed: onCopyUri,
                icon: const Icon(Icons.copy, size: 14),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
