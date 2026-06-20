/// Code editor widget factory for MCP UI DSL v1.1
///
/// Provides a code editor with syntax highlighting and line numbers.
library code_editor_factory;

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Editor palette — `(background, text, lineNumber)` triple resolved
/// from the `theme` property. Each entry is the canonical fixed color
/// set for that named editor theme.
class _EditorPalette {
  const _EditorPalette(this.background, this.text, this.lineNumber);
  final Color background;
  final Color text;
  final Color lineNumber;
}

/// Languages the spec § 10.14 enum advertises. The runtime currently
/// renders all of them as plain monospace text — actual syntax
/// highlighting is on a separate implementation track. Listing the
/// canonical names here keeps the runtime in lockstep with the spec
/// (no silent fall-through when authors emit a documented value) and
/// gives the future highlighter a single source of truth.
const Set<String> _editorSupportedLanguages = {
  'plaintext',
  'javascript',
  'typescript',
  'python',
  'java',
  'kotlin',
  'swift',
  'rust',
  'c',
  'cpp',
  'csharp',
  'ruby',
  'php',
  'sql',
};

_EditorPalette _resolveEditorPalette(String name) {
  switch (name) {
    case 'vsLight':
    case 'light':
      return const _EditorPalette(
          Color(0xFFFFFFFF), Color(0xFF1F2328), Color(0xFF6E7681));
    case 'monokai':
      return const _EditorPalette(
          Color(0xFF272822), Color(0xFFF8F8F2), Color(0xFF75715E));
    case 'solarizedLight':
      return const _EditorPalette(
          Color(0xFFFDF6E3), Color(0xFF586E75), Color(0xFF93A1A1));
    case 'solarizedDark':
      return const _EditorPalette(
          Color(0xFF002B36), Color(0xFF93A1A1), Color(0xFF586E75));
    case 'github':
      return const _EditorPalette(
          Color(0xFFFFFFFF), Color(0xFF24292F), Color(0xFF6E7781));
    case 'dracula':
      return const _EditorPalette(
          Color(0xFF282A36), Color(0xFFF8F8F2), Color(0xFF6272A4));
    case 'vsDark':
    case 'dark':
    default:
      return const _EditorPalette(
          Color(0xFF1E1E1E), Color(0xFFD4D4D4), Color(0xFF858585));
  }
}

/// Factory for Code Editor widgets
class CodeEditorWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties — spec §2.6.0 binding shorthand: when `code` is
    // omitted, read from the `binding` state path.
    final binding = properties['binding'] as String?;
    final rawCode = properties['code'] != null
        ? context.resolve(properties['code'])
        : (binding != null ? context.getState(binding) : '');
    final code = rawCode?.toString() ?? '';
    final rawLang = properties['language'] as String? ?? 'plaintext';
    // Canonicalise legacy `plain` to `plaintext`; keep declared spec
    // languages as-is so callers can later add highlighting per name.
    final language = rawLang == 'plain' ? 'plaintext' : rawLang;
    // Recognise the spec-declared set so a future highlighter can read
    // off the same vocabulary; unknown values fall back to plaintext.
    final declaredLanguage = _editorSupportedLanguages.contains(language)
        ? language
        : 'plaintext';
    final readOnly = properties['readOnly'] as bool? ?? false;
    final showLineNumbers = properties['showLineNumbers'] as bool? ?? true;
    final fontSize = (properties['fontSize'] as num?)?.toDouble() ?? 14.0;
    // Spec §10.14: `theme` selects light / dark palette. Defaults to
    // 'dark' to match the VS Code convention most code surfaces ship
    // with. `tabSize` is parsed but not yet wired into rendering.
    final theme = (properties['theme'] as String?) ?? 'dark';
    // ignore: unused_local_variable
    final tabSize = (properties['tabSize'] as num?)?.toInt() ?? 2;
    final lineHeight = (properties['lineHeight'] as num?)?.toDouble() ?? 1.5;
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble() ?? 300.0;

    // Theme palette — author-supplied properties win, then the
    // `theme` prop selects a named palette (spec § 10.14:
    // `vsLight` / `vsDark` / `monokai` / `solarizedLight` /
    // `solarizedDark` / `github` / `dracula`). Legacy `light` / `dark`
    // strings are accepted as aliases of `vsLight` / `vsDark`.
    final palette = _resolveEditorPalette(theme);
    final defaultBg = palette.background;
    final defaultText = palette.text;
    final defaultLineNum = palette.lineNumber;
    final backgroundColor =
        parseColor(properties['backgroundColor'], context) ?? defaultBg;
    final textColor =
        parseColor(properties['textColor'], context) ?? defaultText;
    final lineNumberColor =
        parseColor(properties['lineNumberColor'], context) ?? defaultLineNum;

    // Action handlers
    final onChange = (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

    Widget editor = _CodeEditor(
      code: code,
      language: declaredLanguage,
      readOnly: readOnly,
      showLineNumbers: showLineNumbers,
      fontSize: fontSize,
      lineHeight: lineHeight,
      backgroundColor: backgroundColor,
      textColor: textColor,
      lineNumberColor: lineNumberColor,
      onChange: onChange,
      context: context,
    );

    editor = SizedBox(
      width: width,
      height: height,
      child: editor,
    );

    return applyCommonWrappers(editor, properties, context);
  }
}

class _CodeEditor extends StatefulWidget {
  final String code;
  final String language;
  final bool readOnly;
  final bool showLineNumbers;
  final double fontSize;
  final double lineHeight;
  final Color backgroundColor;
  final Color textColor;
  final Color lineNumberColor;
  final Map<String, dynamic>? onChange;
  final RenderContext context;

  const _CodeEditor({
    required this.code,
    required this.language,
    required this.readOnly,
    required this.showLineNumbers,
    required this.fontSize,
    required this.lineHeight,
    required this.backgroundColor,
    required this.textColor,
    required this.lineNumberColor,
    this.onChange,
    required this.context,
  });

  @override
  State<_CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<_CodeEditor> {
  late TextEditingController _controller;
  late ScrollController _scrollController;
  late ScrollController _lineNumberScrollController;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.code);
    _scrollController = ScrollController();
    _lineNumberScrollController = ScrollController();

    // Sync scroll between line numbers and code
    _scrollController.addListener(_syncScroll);
  }

  @override
  void didUpdateWidget(_CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the editor in sync when the bound `code` prop changes after
    // the first build (e.g. state is hydrated asynchronously). Only push
    // the new text when it actually differs — rewriting the same string
    // would clobber the caret position.
    if (widget.code != _controller.text && widget.code != oldWidget.code) {
      final selection = _controller.selection;
      _controller.text = widget.code;
      if (selection.start <= widget.code.length &&
          selection.end <= widget.code.length) {
        _controller.selection = selection;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _lineNumberScrollController.dispose();
    super.dispose();
  }

  void _syncScroll() {
    if (_lineNumberScrollController.hasClients) {
      _lineNumberScrollController.jumpTo(_scrollController.offset);
    }
  }

  void _onChanged(String value) {
    if (widget.onChange != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'value': value,
            'lineCount': value.split('\n').length,
          }
        },
      );
      widget.context.actionHandler.execute(widget.onChange!, eventContext);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _controller.text.split('\n');
    final lineCount = lines.length;

    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.lineNumberColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line numbers
          if (widget.showLineNumbers)
            Container(
              width: 50,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: widget.lineNumberColor.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: ListView.builder(
                controller: _lineNumberScrollController,
                itemCount: lineCount,
                itemBuilder: (context, index) {
                  return SizedBox(
                    height: widget.fontSize * widget.lineHeight,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: widget.fontSize,
                        height: widget.lineHeight,
                        color: widget.lineNumberColor,
                      ),
                    ),
                  );
                },
              ),
            ),
          // Code editor
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _controller,
                readOnly: widget.readOnly,
                maxLines: null,
                onChanged: _onChanged,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: widget.fontSize,
                  height: widget.lineHeight,
                  color: widget.textColor,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
