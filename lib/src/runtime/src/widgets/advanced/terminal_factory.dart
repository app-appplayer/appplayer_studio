/// Terminal widget factory for MCP UI DSL v1.1
///
/// Provides a terminal-like display with command history.
library terminal_factory;

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Terminal widgets
class TerminalWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final lines =
        context.resolve<List<dynamic>>(properties['lines']) as List<dynamic>? ??
            [];
    final prompt = properties['prompt'] as String? ?? '\$ ';
    final showInput = properties['showInput'] as bool? ?? true;
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble() ?? 300.0;
    final fontSize = (properties['fontSize'] as num?)?.toDouble() ?? 14.0;
    final maxLines = properties['maxLines'] as int? ?? 1000;

    // Theme palette — author-supplied properties win, then the optional
    // `theme: 'light' | 'dark'` prop chooses between palettes. Defaults
    // to 'dark' to match the terminal-emulator convention.
    final theme = (properties['theme'] as String?) ?? 'dark';
    final isLightTerminal = theme == 'light';
    final defaultBg = isLightTerminal
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF1E1E1E);
    final defaultText = isLightTerminal
        ? const Color(0xFF1F2328)
        : const Color(0xFF00FF00);
    final defaultPrompt = isLightTerminal
        ? const Color(0xFF0969DA)
        : const Color(0xFF00AAFF);
    final backgroundColor =
        parseColor(properties['backgroundColor'], context) ?? defaultBg;
    final textColor =
        parseColor(properties['textColor'], context) ?? defaultText;
    final promptColor =
        parseColor(properties['promptColor'], context) ?? defaultPrompt;

    // Action handlers
    final onCommand = (properties['onCommand'] ?? properties['command']) as Map<String, dynamic>?;

    Widget terminal = _Terminal(
      lines: lines.map((l) => l.toString()).toList(),
      prompt: prompt,
      showInput: showInput,
      fontSize: fontSize,
      maxLines: maxLines,
      backgroundColor: backgroundColor,
      textColor: textColor,
      promptColor: promptColor,
      onCommand: onCommand,
      context: context,
    );

    terminal = SizedBox(
      width: width,
      height: height,
      child: terminal,
    );

    return applyCommonWrappers(terminal, properties, context);
  }
}

class _Terminal extends StatefulWidget {
  final List<String> lines;
  final String prompt;
  final bool showInput;
  final double fontSize;
  final int maxLines;
  final Color backgroundColor;
  final Color textColor;
  final Color promptColor;
  final Map<String, dynamic>? onCommand;
  final RenderContext context;

  const _Terminal({
    required this.lines,
    required this.prompt,
    required this.showInput,
    required this.fontSize,
    required this.maxLines,
    required this.backgroundColor,
    required this.textColor,
    required this.promptColor,
    this.onCommand,
    required this.context,
  });

  @override
  State<_Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<_Terminal> {
  late List<String> _lines;
  late TextEditingController _inputController;
  late ScrollController _scrollController;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _lines = List.from(widget.lines);
    _inputController = TextEditingController();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submitCommand(String command) {
    if (command.isEmpty) return;

    setState(() {
      _lines.add('${widget.prompt}$command');

      // Trim to max lines
      if (_lines.length > widget.maxLines) {
        _lines.removeRange(0, _lines.length - widget.maxLines);
      }
    });

    _inputController.clear();

    // Execute command action
    if (widget.onCommand != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'command': command,
            'lineCount': _lines.length,
          }
        },
      );
      widget.context.actionHandler.execute(widget.onCommand!, eventContext);
    }

    // Scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Add output line to terminal
  void addLine(String line) {
    setState(() {
      _lines.add(line);
      if (_lines.length > widget.maxLines) {
        _lines.removeRange(0, _lines.length - widget.maxLines);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Output area
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                return _buildLine(_lines[index]);
              },
            ),
          ),
          // Input area
          if (widget.showInput)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: widget.textColor.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    widget.prompt,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: widget.fontSize,
                      color: widget.promptColor,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: widget.fontSize,
                        color: widget.textColor,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                      onSubmitted: _submitCommand,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLine(String line) {
    // Check if line starts with prompt
    if (line.startsWith(widget.prompt)) {
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: widget.prompt,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: widget.fontSize,
                color: widget.promptColor,
              ),
            ),
            TextSpan(
              text: line.substring(widget.prompt.length),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: widget.fontSize,
                color: widget.textColor,
              ),
            ),
          ],
        ),
      );
    }

    // Parse ANSI color codes (basic support)
    return Text(
      _stripAnsiCodes(line),
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: widget.fontSize,
        color: widget.textColor,
      ),
    );
  }

  /// Strip ANSI escape codes from text
  String _stripAnsiCodes(String text) {
    return text.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
  }
}
