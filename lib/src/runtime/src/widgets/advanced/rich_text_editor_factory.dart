import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `richTextEditor` (spec §10.27).
///
/// The bound value is **HTML** (or Markdown via `format`), and that choice is
/// the whole reason this needed a decision rather than a definition: an
/// editor's value format is a contract every consumer of the document
/// inherits, and a proprietary delta model would leave the content unreadable
/// to anything but the editor that produced it.
///
/// Sanitisation is not optional. §7.5 applies to this value exactly as to any
/// other author-supplied markup, and the whitelist here is the one the spec
/// states — anything outside it is **stripped, not escaped**, so a document
/// cannot smuggle markup through the editor.
class RichTextEditorFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = stringOf(properties['binding'], context);
    final format = context.resolve<String?>(properties['format']) ?? 'html';
    final placeholder = context.resolve<String?>(properties['placeholder']);
    final minHeight =
        context.resolve<num?>(properties['minHeight'])?.toDouble() ?? 160.0;
    final maxLength = context.resolve<num?>(properties['maxLength'])?.toInt();
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;
    final toolbar = (context.resolve<List<dynamic>?>(properties['toolbar']) ??
            const ['bold', 'italic', 'link', 'bulletList', 'heading'])
        .map((e) => e.toString())
        .toSet();
    final onChange = actionOf(properties['onChange'], context);

    final current = binding != null
        ? (context.getState(binding)?.toString() ?? '')
        : (context.resolve<String?>(properties['value']) ?? '');

    return _RichTextEditor(
      initialValue: current,
      markdown: format == 'markdown',
      placeholder: placeholder,
      minHeight: minHeight,
      maxLength: maxLength,
      enabled: enabled,
      toolbar: toolbar,
      onChanged: (value) {
        final clean = sanitizeRichText(value, markdown: format == 'markdown');
        if (binding != null) context.setValue(binding, clean);
        if (onChange != null) {
          context.actionHandler.execute(
            onChange,
            context.createChildContext(
              variables: {
                'event': {'value': clean, 'type': 'change'},
              },
            ),
          );
        }
      },
    );
  }
}

/// Inline marks and block elements the spec admits; `img` is allowed with an
/// `AssetRef` src.
const _allowedTags = {
  'strong', 'b', 'em', 'i', 'u', 's', 'code', 'a',
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'blockquote', 'pre', 'br', 'img',
};

/// Strips everything outside the declared subset (spec §10.27, §7.5).
///
/// Stripped rather than escaped: escaping would render the offending markup as
/// visible text, which looks like corruption to the author and still carries
/// the payload through to the next consumer.
String sanitizeRichText(String input, {bool markdown = false}) {
  if (markdown) {
    // Markdown carries no tags of its own; the risk is inline HTML, so the
    // same tag filter applies.
    return _stripTags(input);
  }
  return _stripTags(input);
}

String _stripTags(String input) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final open = input.indexOf('<', i);
    if (open == -1) {
      buffer.write(input.substring(i));
      break;
    }
    buffer.write(input.substring(i, open));
    final close = input.indexOf('>', open);
    if (close == -1) break; // unterminated tag: drop the remainder
    final raw = input.substring(open + 1, close).trim();
    final name = raw
        .replaceFirst('/', '')
        .split(RegExp(r'[\s>]'))
        .first
        .toLowerCase();
    if (_allowedTags.contains(name)) {
      // Attributes are dropped except href/src, which carry the destination.
      final isClosing = raw.startsWith('/');
      if (isClosing) {
        buffer.write('</$name>');
      } else {
        final href = RegExp(r'''(?:href|src)\s*=\s*["']([^"']*)["']''')
            .firstMatch(raw)
            ?.group(1);
        if (href != null && _safeUrl(href)) {
          buffer.write('<$name ${name == 'img' ? 'src' : 'href'}="$href">');
        } else {
          buffer.write('<$name>');
        }
      }
    }
    i = close + 1;
  }
  return buffer.toString();
}

bool _safeUrl(String url) {
  final lower = url.trim().toLowerCase();
  // Same refusal list as §7.3.4: these are not destinations.
  return !lower.startsWith('javascript:') &&
      !lower.startsWith('vbscript:') &&
      !lower.startsWith('file:');
}

class _RichTextEditor extends StatefulWidget {
  const _RichTextEditor({
    required this.initialValue,
    required this.markdown,
    required this.minHeight,
    required this.enabled,
    required this.toolbar,
    required this.onChanged,
    this.placeholder,
    this.maxLength,
  });

  final String initialValue;
  final bool markdown;
  final double minHeight;
  final bool enabled;
  final Set<String> toolbar;
  final ValueChanged<String> onChanged;
  final String? placeholder;
  final int? maxLength;

  @override
  State<_RichTextEditor> createState() => _RichTextEditorState();
}

class _RichTextEditorState extends State<_RichTextEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Wraps the selection, or inserts an empty pair at the caret.
  void _wrap(String open, String close) {
    final selection = _controller.selection;
    final text = _controller.text;
    if (!selection.isValid) return;
    final selected = selection.textInside(text);
    final replaced = '$open$selected$close';
    _controller.value = _controller.value.copyWith(
      text: selection.textBefore(text) + replaced + selection.textAfter(text),
      selection: TextSelection.collapsed(
        offset: selection.start + open.length + selected.length,
      ),
    );
    widget.onChanged(_controller.text);
  }

  void _prefixLine(String prefix) {
    final selection = _controller.selection;
    final text = _controller.text;
    if (!selection.isValid) return;
    final lineStart = text.lastIndexOf('\n', (selection.start - 1).clamp(0, text.length)) + 1;
    _controller.value = _controller.value.copyWith(
      text: text.substring(0, lineStart) + prefix + text.substring(lineStart),
      selection: TextSelection.collapsed(
        offset: selection.start + prefix.length,
      ),
    );
    widget.onChanged(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final md = widget.markdown;
    final controls = <Widget>[
      // A control absent from the toolbar is also absent as a shortcut, or the
      // toolbar lies about what the document can contain (spec §10.27).
      if (widget.toolbar.contains('bold'))
        _ToolButton(
          icon: Icons.format_bold,
          tooltip: 'Bold',
          onTap: () => _wrap(md ? '**' : '<strong>', md ? '**' : '</strong>'),
        ),
      if (widget.toolbar.contains('italic'))
        _ToolButton(
          icon: Icons.format_italic,
          tooltip: 'Italic',
          onTap: () => _wrap(md ? '_' : '<em>', md ? '_' : '</em>'),
        ),
      if (widget.toolbar.contains('underline') && !md)
        _ToolButton(
          icon: Icons.format_underlined,
          tooltip: 'Underline',
          onTap: () => _wrap('<u>', '</u>'),
        ),
      if (widget.toolbar.contains('code'))
        _ToolButton(
          icon: Icons.code,
          tooltip: 'Code',
          onTap: () => _wrap(md ? '`' : '<code>', md ? '`' : '</code>'),
        ),
      if (widget.toolbar.contains('link'))
        _ToolButton(
          icon: Icons.link,
          tooltip: 'Link',
          onTap: () => _wrap(md ? '[' : '<a href="">', md ? '](https://)' : '</a>'),
        ),
      if (widget.toolbar.contains('heading'))
        _ToolButton(
          icon: Icons.title,
          tooltip: 'Heading',
          onTap: () => md ? _prefixLine('## ') : _wrap('<h2>', '</h2>'),
        ),
      if (widget.toolbar.contains('bulletList'))
        _ToolButton(
          icon: Icons.format_list_bulleted,
          tooltip: 'Bulleted list',
          onTap: () => md ? _prefixLine('- ') : _wrap('<ul><li>', '</li></ul>'),
        ),
      if (widget.toolbar.contains('orderedList'))
        _ToolButton(
          icon: Icons.format_list_numbered,
          tooltip: 'Numbered list',
          onTap: () => md ? _prefixLine('1. ') : _wrap('<ol><li>', '</li></ol>'),
        ),
      if (widget.toolbar.contains('quote'))
        _ToolButton(
          icon: Icons.format_quote,
          tooltip: 'Quote',
          onTap: () =>
              md ? _prefixLine('> ') : _wrap('<blockquote>', '</blockquote>'),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controls.isNotEmpty)
          Wrap(children: widget.enabled ? controls : const []),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: widget.minHeight),
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            maxLines: null,
            minLines: 4,
            inputFormatters: widget.maxLength == null
                ? null
                : [LengthLimitingTextInputFormatter(widget.maxLength)],
            decoration: InputDecoration(
              hintText: widget.placeholder,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            onChanged: widget.onChanged,
          ),
        ),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );
}
