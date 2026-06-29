/// Studio-themed document panel — a file list (left) + [VbuDocumentViewer]
/// (right) split, the L0 shell of the Studio viewer kit.
///
/// Data-injected like the runtime `file_explorer` widget: the host supplies the
/// current directory [entries] and loads a file's content through [onLoad]; the
/// panel owns selection + the view/edit chrome only. Navigation (into a folder,
/// up) and persistence ([onSave]) are host callbacks — so the same panel serves
/// any built-in (Ops project files, an asset's folder, …) without the widget
/// touching the filesystem itself.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../tokens.dart';
import 'vbu_document_viewer.dart';

/// One entry in the file list.
class VbuFileEntry {
  const VbuFileEntry({
    required this.name,
    required this.path,
    this.isDir = false,
  });
  final String name;
  final String path;
  final bool isDir;
}

/// Loads a file's content (text for text kinds, bytes for images).
typedef VbuLoadFile = Future<({String? text, Uint8List? bytes})> Function(
  VbuFileEntry entry,
);

class VbuDocumentPanel extends StatefulWidget {
  const VbuDocumentPanel({
    super.key,
    required this.entries,
    required this.onLoad,
    this.onSave,
    this.onEnterDir,
    this.onUp,
    this.onRefresh,
    this.breadcrumb = '',
  });

  /// Current directory listing (host feeds; dirs + files).
  final List<VbuFileEntry> entries;

  /// Load a file's content when it is selected.
  final VbuLoadFile onLoad;

  /// Persist an edited text file. When null, the viewer is read-only.
  final Future<void> Function(VbuFileEntry entry, String text)? onSave;

  /// Navigate into a directory (host updates [entries] + [breadcrumb]).
  final ValueChanged<VbuFileEntry>? onEnterDir;

  /// Go up one directory (null disables the Up affordance — at root).
  final VoidCallback? onUp;

  /// Re-list the current directory.
  final VoidCallback? onRefresh;

  /// Path label shown in the list header.
  final String breadcrumb;

  @override
  State<VbuDocumentPanel> createState() => _VbuDocumentPanelState();
}

class _VbuDocumentPanelState extends State<VbuDocumentPanel> {
  VbuFileEntry? _selected;
  String? _text;
  Uint8List? _bytes;
  bool _loading = false;

  Future<void> _open(VbuFileEntry e) async {
    setState(() {
      _selected = e;
      _loading = true;
      _text = null;
      _bytes = null;
    });
    try {
      final r = await widget.onLoad(e);
      if (!mounted) return;
      setState(() {
        _text = r.text;
        _bytes = r.bytes;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _text = 'Failed to load: $err';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderDefault),
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(width: 240, child: _fileList(c)),
          VerticalDivider(width: 1, color: c.borderDefault),
          Expanded(child: _viewer(c)),
        ],
      ),
    );
  }

  Widget _fileList(VbuPalette c) {
    return Container(
      color: c.surface2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Header — breadcrumb + up + refresh.
          Container(
            height: 38,
            padding: const EdgeInsets.only(left: VbuTokens.space3, right: 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.borderDefault)),
            ),
            child: Row(
              children: <Widget>[
                if (widget.onUp != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    tooltip: 'Up',
                    icon: Icon(Icons.arrow_upward, color: c.textSecondary),
                    onPressed: widget.onUp,
                  ),
                Expanded(
                  child: Text(
                    widget.breadcrumb.isEmpty ? 'Files' : widget.breadcrumb,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 11,
                      color: c.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onRefresh != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    tooltip: 'Refresh',
                    icon: Icon(Icons.refresh, color: c.textSecondary),
                    onPressed: widget.onRefresh,
                  ),
              ],
            ),
          ),
          Expanded(
            child: widget.entries.isEmpty
                ? Center(
                    child: Text(
                      'empty',
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 11,
                        color: c.textTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.entries.length,
                    itemBuilder: (_, i) => _row(c, widget.entries[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(VbuPalette c, VbuFileEntry e) {
    final selected = !e.isDir && _selected?.path == e.path;
    return InkWell(
      onTap: () =>
          e.isDir ? widget.onEnterDir?.call(e) : _open(e),
      child: Container(
        color: selected ? c.surface3 : null,
        padding: const EdgeInsets.symmetric(
          horizontal: VbuTokens.space3,
          vertical: 5,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              e.isDir
                  ? Icons.folder_outlined
                  : _fileIcon(e.name),
              size: 14,
              color: e.isDir ? c.amber : c.textTertiary,
            ),
            const SizedBox(width: VbuTokens.space2),
            Expanded(
              child: Text(
                e.name,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 12,
                  color: selected ? c.textPrimary : c.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _viewer(VbuPalette c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final sel = _selected;
    if (sel == null) {
      return Center(
        child: Text(
          'Select a file',
          style: TextStyle(color: c.textTertiary, fontSize: 12),
        ),
      );
    }
    return VbuDocumentViewer(
      key: ValueKey(sel.path),
      path: sel.path,
      text: _text,
      bytes: _bytes,
      editable: widget.onSave != null,
      onSave: widget.onSave == null
          ? null
          : (t) => widget.onSave!(sel, t),
    );
  }

  static IconData _fileIcon(String name) {
    switch (vbuDocKindForPath(name)) {
      case VbuDocKind.markdown:
        return Icons.article_outlined;
      case VbuDocKind.code:
        return Icons.description_outlined;
      case VbuDocKind.image:
        return Icons.image_outlined;
      case VbuDocKind.pdf:
        return Icons.picture_as_pdf_outlined;
      case VbuDocKind.binary:
        return Icons.insert_drive_file_outlined;
    }
  }
}
