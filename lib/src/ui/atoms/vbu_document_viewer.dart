/// Studio-themed multi-format document viewer + lightweight editor.
///
/// Part of the Studio viewer kit (an IDE-grade composition layer for built-in
/// apps — Ops / App Builder / Scene Builder). It is deliberately Studio-only
/// (coded, not a portable DSL widget): the portable *display* path lives in
/// `flutter_mcp_ui_runtime` (markdown / code / table / image / webview, shared
/// with AppPlayer); this kit wraps the same renderers in the Studio theme and
/// adds the IDE chrome (view↔edit toggle, save) that doesn't belong in a
/// sandboxed runtime widget.
///
/// Data-injected (no filesystem access of its own): the host supplies [text]
/// (text kinds) or [bytes] (images), and is called back through [onSave] — so
/// the widget stays pure and reusable. Picks a renderer by the [path]
/// extension. PDF is a placeholder until the runtime ships a `pdf` widget.
library;

import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../tokens.dart';

/// Renderer chosen for a document, by file extension.
enum VbuDocKind { markdown, code, image, pdf, binary }

VbuDocKind vbuDocKindForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'md':
    case 'markdown':
      return VbuDocKind.markdown;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'bmp':
      return VbuDocKind.image;
    case 'pdf':
      return VbuDocKind.pdf;
    case 'dart':
    case 'js':
    case 'ts':
    case 'py':
    case 'json':
    case 'yaml':
    case 'yml':
    case 'csv':
    case 'tsv':
    case 'log':
    case 'txt':
    case 'text':
    case 'sh':
    case 'html':
    case 'css':
    case 'xml':
    case 'toml':
    case 'ini':
    case 'sql':
    case 'kt':
    case 'swift':
    case 'go':
    case 'rs':
    case 'c':
    case 'h':
    case 'cpp':
    case 'java':
    case 'rb':
    case 'php':
      return VbuDocKind.code;
    case '':
      return VbuDocKind.code; // extensionless — treat as text
    default:
      return VbuDocKind.binary;
  }
}

class VbuDocumentViewer extends StatefulWidget {
  const VbuDocumentViewer({
    super.key,
    required this.path,
    this.text,
    this.bytes,
    this.editable = false,
    this.onSave,
  });

  /// File path or name — drives the title + the renderer (by extension).
  final String path;

  /// Text content for text/markdown/code kinds.
  final String? text;

  /// Raw bytes for image / binary kinds (preferred for images).
  final Uint8List? bytes;

  /// When true and the kind is text-based, a view↔edit toggle + Save appear.
  final bool editable;

  /// Called with the edited text when the user saves. The host persists it
  /// (e.g. `fs.write`); the viewer only edits in memory.
  final ValueChanged<String>? onSave;

  @override
  State<VbuDocumentViewer> createState() => _VbuDocumentViewerState();
}

class _VbuDocumentViewerState extends State<VbuDocumentViewer> {
  late TextEditingController _ctl;
  bool _editing = false;
  bool _dirty = false;

  VbuDocKind get _kind => vbuDocKindForPath(widget.path);
  bool get _textKind =>
      _kind == VbuDocKind.markdown || _kind == VbuDocKind.code;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.text ?? '');
    _ctl.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void didUpdateWidget(covariant VbuDocumentViewer old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.text != widget.text) {
      _ctl.text = widget.text ?? '';
      _editing = false;
      _dirty = false;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save() {
    widget.onSave?.call(_ctl.text);
    setState(() => _dirty = false);
  }

  String _basename(String p) {
    final i = p.replaceAll('\\', '/').lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _toolbar(c),
        Expanded(
          child: Container(
            color: c.surface,
            child: _body(c),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(VbuPalette c) {
    final canEdit = widget.editable && _textKind && widget.onSave != null;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(bottom: BorderSide(color: c.borderDefault)),
      ),
      child: Row(
        children: <Widget>[
          Icon(_iconForKind(_kind), size: 14, color: c.textSecondary),
          const SizedBox(width: VbuTokens.space2),
          Expanded(
            child: Text(
              _basename(widget.path),
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _kindChip(c),
          if (canEdit) ...[
            const SizedBox(width: VbuTokens.space2),
            _toolbarButton(
              c,
              icon: _editing ? Icons.visibility_outlined : Icons.edit_outlined,
              label: _editing ? 'View' : 'Edit',
              onTap: () => setState(() => _editing = !_editing),
            ),
            if (_dirty) ...[
              const SizedBox(width: VbuTokens.space1),
              _toolbarButton(
                c,
                icon: Icons.save_outlined,
                label: 'Save',
                accent: true,
                onTap: _save,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _kindChip(VbuPalette c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        ),
        child: Text(
          _kind.name,
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 10,
            color: c.textTertiary,
          ),
        ),
      );

  Widget _toolbarButton(
    VbuPalette c, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    final fg = accent ? c.mint : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(VbuPalette c) {
    switch (_kind) {
      case VbuDocKind.markdown:
        return (_editing) ? _editor(c) : _markdownView(c);
      case VbuDocKind.code:
        return (_editing) ? _editor(c) : _codeView(c);
      case VbuDocKind.image:
        return _imageView(c);
      case VbuDocKind.pdf:
        return _placeholder(
          c,
          Icons.picture_as_pdf_outlined,
          'PDF preview pending',
          'A `pdf` runtime widget is on the way. For now, open the file '
              'externally.',
        );
      case VbuDocKind.binary:
        return _placeholder(
          c,
          Icons.insert_drive_file_outlined,
          'Binary / unsupported',
          'No in-app viewer for this format yet.',
        );
    }
  }

  Widget _markdownView(VbuPalette c) => Markdown(
        data: widget.text ?? '',
        selectable: true,
        padding: const EdgeInsets.all(VbuTokens.space4),
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(color: c.textPrimary, fontSize: 14, height: 1.6),
          h1: TextStyle(color: c.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
          h2: TextStyle(color: c.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
          h3: TextStyle(color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
          code: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 12.5,
            color: c.mint,
            backgroundColor: c.surface2,
          ),
          codeblockDecoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          ),
          a: TextStyle(color: c.blue),
          blockquoteDecoration: BoxDecoration(
            color: c.surface2,
            border: Border(left: BorderSide(color: c.borderStrong, width: 3)),
          ),
        ),
      );

  Widget _codeView(VbuPalette c) => SingleChildScrollView(
        padding: const EdgeInsets.all(VbuTokens.space3),
        child: SizedBox(
          width: double.infinity,
          child: SelectableText(
            widget.text ?? '',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 12.5,
              color: c.textPrimary,
              height: 1.55,
            ),
          ),
        ),
      );

  Widget _editor(VbuPalette c) => Padding(
        padding: const EdgeInsets.all(VbuTokens.space3),
        child: TextField(
          controller: _ctl,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 12.5,
            color: c.textPrimary,
            height: 1.55,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
          ),
        ),
      );

  Widget _imageView(VbuPalette c) {
    final Widget img;
    if (widget.bytes != null) {
      img = Image.memory(widget.bytes!, fit: BoxFit.contain);
    } else {
      img = Image.file(File(widget.path), fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _placeholder(
                c,
                Icons.broken_image_outlined,
                'Cannot load image',
                widget.path,
              ));
    }
    return Container(
      color: c.surface,
      padding: const EdgeInsets.all(VbuTokens.space4),
      child: Center(child: InteractiveViewer(child: img)),
    );
  }

  Widget _placeholder(
    VbuPalette c,
    IconData icon,
    String title,
    String detail,
  ) =>
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space2),
            Text(
              title,
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: VbuTokens.space1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space6),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  color: c.textTertiary,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      );

  static IconData _iconForKind(VbuDocKind k) {
    switch (k) {
      case VbuDocKind.markdown:
        return Icons.article_outlined;
      case VbuDocKind.code:
        return Icons.code;
      case VbuDocKind.image:
        return Icons.image_outlined;
      case VbuDocKind.pdf:
        return Icons.picture_as_pdf_outlined;
      case VbuDocKind.binary:
        return Icons.insert_drive_file_outlined;
    }
  }
}
