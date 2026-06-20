/// Markdown widget factory for MCP UI DSL v1.1
///
/// Renders markdown content to Flutter widgets.
library markdown_factory;

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Markdown widgets
class MarkdownWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Canonical key is `text` per spec §10.17 (matching text widget per
    // 17_Naming §17.3.2); `content` is a legacy alias from v1.0 and is
    // accepted per §18.2.10 (runtimes MUST accept registered aliases).
    final content =
        context.resolve<String>(properties['text']) as String? ??
            context.resolve<String>(properties['content']) as String? ??
            '';
    final selectable = properties['selectable'] as bool? ?? false;
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble();

    // Style properties
    final textColor = parseColor(properties['textColor'], context);
    final backgroundColor = parseColor(properties['backgroundColor'], context);
    // Theme-adaptive defaults — links fall back to the active theme's
    // primary slot; inline/code block background uses a soft onSurface
    // tint so it reads as a recess in both light and dark themes.
    final linkColor = parseColor(properties['linkColor'], context) ??
        context.themeManager.getColorValue('primary') ??
        Colors.blue;
    final codeBackgroundColor =
        parseColor(properties['codeBackgroundColor'], context) ??
            (context.themeManager
                .getColorValue('onSurface')
                ?.withValues(alpha: 0.08)) ??
            Colors.grey.withValues(alpha: 0.1);
    final fontSize = (properties['fontSize'] as num?)?.toDouble() ?? 14.0;

    // Action handlers
    final onLinkTap = properties['onLinkTap'] as Map<String, dynamic>?;

    Widget markdown = _MarkdownRenderer(
      content: content,
      selectable: selectable,
      textColor: textColor,
      backgroundColor: backgroundColor,
      linkColor: linkColor,
      codeBackgroundColor: codeBackgroundColor,
      fontSize: fontSize,
      onLinkTap: onLinkTap,
      context: context,
    );

    if (width != null || height != null) {
      markdown = SizedBox(
        width: width,
        height: height,
        child: markdown,
      );
    }

    return applyCommonWrappers(markdown, properties, context);
  }
}

class _MarkdownRenderer extends StatelessWidget {
  final String content;
  final bool selectable;
  final Color? textColor;
  final Color? backgroundColor;
  final Color linkColor;
  final Color codeBackgroundColor;
  final double fontSize;
  final Map<String, dynamic>? onLinkTap;
  final RenderContext context;

  const _MarkdownRenderer({
    required this.content,
    required this.selectable,
    this.textColor,
    this.backgroundColor,
    required this.linkColor,
    required this.codeBackgroundColor,
    required this.fontSize,
    this.onLinkTap,
    required this.context,
  });

  @override
  Widget build(BuildContext buildContext) {
    final widgets = _parseMarkdown(content, buildContext);

    // RichText does not inherit from DefaultTextStyle, so wrap the whole
    // markdown tree in one that resolves `textColor` (when the DSL does not
    // supply one) against the ambient theme. Without this the inline spans
    // can paint with no explicit color on a themed surface and appear
    // invisible (e.g. white-on-white in card surfaces).
    final ambient = DefaultTextStyle.of(buildContext).style;
    final resolvedColor = textColor ??
        ambient.color ??
        Theme.of(buildContext).textTheme.bodyMedium?.color;

    return DefaultTextStyle.merge(
      style: TextStyle(color: resolvedColor, fontSize: fontSize),
      child: Container(
        decoration: BoxDecoration(
          color: backgroundColor,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widgets,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _parseMarkdown(String markdown, BuildContext buildContext) {
    final lines = markdown.split('\n');
    final widgets = <Widget>[];
    final buffer = StringBuffer();
    bool inCodeBlock = false;
    String? codeLanguage;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Code block handling
      if (line.startsWith('```')) {
        if (inCodeBlock) {
          // End code block
          widgets.add(_buildCodeBlock(buffer.toString(), codeLanguage));
          buffer.clear();
          inCodeBlock = false;
          codeLanguage = null;
        } else {
          // Start code block
          if (buffer.isNotEmpty) {
            widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
            buffer.clear();
          }
          inCodeBlock = true;
          codeLanguage = line.length > 3 ? line.substring(3).trim() : null;
        }
        continue;
      }

      if (inCodeBlock) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.write(line);
        continue;
      }

      // Empty line marks paragraph break
      if (line.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
          buffer.clear();
        }
        widgets.add(const SizedBox(height: 8));
        continue;
      }

      // Headers
      if (line.startsWith('#')) {
        if (buffer.isNotEmpty) {
          widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
          buffer.clear();
        }
        widgets.add(_buildHeader(line, buildContext));
        continue;
      }

      // Horizontal rule
      if (RegExp(r'^[-*_]{3,}$').hasMatch(line.trim())) {
        if (buffer.isNotEmpty) {
          widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
          buffer.clear();
        }
        widgets.add(const Divider());
        continue;
      }

      // List items
      if (RegExp(r'^[\*\-\+]\s').hasMatch(line) ||
          RegExp(r'^\d+\.\s').hasMatch(line)) {
        if (buffer.isNotEmpty) {
          widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
          buffer.clear();
        }
        widgets.add(_buildListItem(line, buildContext));
        continue;
      }

      // Blockquote
      if (line.startsWith('>')) {
        if (buffer.isNotEmpty) {
          widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
          buffer.clear();
        }
        widgets.add(_buildBlockquote(line.substring(1).trim(), buildContext));
        continue;
      }

      // Regular text
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(line);
    }

    // Handle remaining content
    if (inCodeBlock && buffer.isNotEmpty) {
      widgets.add(_buildCodeBlock(buffer.toString(), codeLanguage));
    } else if (buffer.isNotEmpty) {
      widgets.addAll(_parseParagraph(buffer.toString(), buildContext));
    }

    return widgets;
  }

  Widget _buildHeader(String line, BuildContext buildContext) {
    int level = 0;
    while (level < line.length && line[level] == '#') {
      level++;
    }
    level = level.clamp(1, 6);

    final text = line.substring(level).trim();
    final fontSizes = [24.0, 22.0, 20.0, 18.0, 16.0, 14.0];
    final headerFontSize = fontSizes[level - 1];

    final inherited = DefaultTextStyle.of(buildContext).style;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: _buildRichText(
        text,
        buildContext,
        baseStyle: TextStyle(
          fontSize: headerFontSize,
          fontWeight: FontWeight.bold,
          color: textColor ?? inherited.color,
        ),
      ),
    );
  }

  Widget _buildCodeBlock(String code, String? language) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: codeBackgroundColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: selectable
            ? SelectableText(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSize - 1,
                  color: textColor,
                ),
              )
            : Text(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSize - 1,
                  color: textColor,
                ),
              ),
      ),
    );
  }

  Widget _buildListItem(String line, BuildContext buildContext) {
    final isOrdered = RegExp(r'^\d+\.\s').hasMatch(line);
    final match = isOrdered
        ? RegExp(r'^(\d+)\.\s(.*)').firstMatch(line)
        : RegExp(r'^[\*\-\+]\s(.*)').firstMatch(line);

    String text;
    String? bullet;

    if (isOrdered && match != null) {
      bullet = '${match.group(1)}.';
      text = match.group(2) ?? '';
    } else if (match != null) {
      bullet = '•';
      text = match.group(1) ?? '';
    } else {
      text = line;
      bullet = '•';
    }

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              bullet,
              style: TextStyle(
                fontSize: fontSize,
                color: textColor,
              ),
            ),
          ),
          Expanded(
            child: _buildRichText(text, buildContext),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockquote(String text, BuildContext buildContext) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(buildContext).dividerColor,
            width: 4,
          ),
        ),
      ),
      child: _buildRichText(
        text,
        buildContext,
        baseStyle: TextStyle(
          fontSize: fontSize,
          fontStyle: FontStyle.italic,
          color: textColor?.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  List<Widget> _parseParagraph(String text, BuildContext buildContext) {
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _buildRichText(text, buildContext),
      ),
    ];
  }

  Widget _buildRichText(String text, BuildContext buildContext, {TextStyle? baseStyle}) {
    // Resolve color against DefaultTextStyle so RichText (which does not
    // inherit it) paints with the theme-correct color when the DSL omits
    // `textColor`.
    final inherited = DefaultTextStyle.of(buildContext).style;
    final fallbackColor = textColor ?? inherited.color;
    final style = baseStyle ??
        TextStyle(
          fontSize: fontSize,
          color: fallbackColor,
        );

    final spans = _parseInlineStyles(text, style, buildContext);

    if (selectable) {
      return SelectableText.rich(
        TextSpan(children: spans),
      );
    }

    return RichText(
      text: TextSpan(
        style: style,
        children: spans,
      ),
    );
  }

  List<InlineSpan> _parseInlineStyles(
      String text, TextStyle baseStyle, BuildContext buildContext) {
    final spans = <InlineSpan>[];
    final regex = RegExp(
      r'(\*\*|__)(.*?)\1|(\*|_)(.*?)\3|(`)(.*?)\5|\[(.*?)\]\((.*?)\)',
    );

    int lastEnd = 0;
    for (final match in regex.allMatches(text)) {
      // Add text before match
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: baseStyle,
        ));
      }

      if (match.group(1) != null) {
        // Bold: **text** or __text__
        spans.add(TextSpan(
          text: match.group(2),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(3) != null) {
        // Italic: *text* or _text_
        spans.add(TextSpan(
          text: match.group(4),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(5) != null) {
        // Inline code: `code`
        spans.add(TextSpan(
          text: match.group(6),
          style: baseStyle.copyWith(
            fontFamily: 'monospace',
            backgroundColor: codeBackgroundColor,
          ),
        ));
      } else if (match.group(7) != null) {
        // Link: [text](url)
        final linkText = match.group(7)!;
        final url = match.group(8)!;
        spans.add(WidgetSpan(
          child: GestureDetector(
            onTap: () => _handleLinkTap(url),
            child: Text(
              linkText,
              style: baseStyle.copyWith(
                color: linkColor,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ));
      }

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: baseStyle,
      ));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: baseStyle));
    }

    return spans;
  }

  void _handleLinkTap(String url) {
    if (onLinkTap != null) {
      final eventContext = context.createChildContext(
        variables: {
          'event': {'url': url}
        },
      );
      context.actionHandler.execute(onLinkTap!, eventContext);
    }
  }
}
