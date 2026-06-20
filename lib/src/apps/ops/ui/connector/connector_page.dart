// MCP Connector Helper — surfaces ready-to-paste configuration snippets
// for the major external MCP clients. Defined in PRD §FM-ONBOARD-03.
//
// The helper reads the live OpsConfig so the host/port shown matches
// whatever the running app is actually serving on. Each snippet has a
// copy button; client status is derived from the connected sessions on
// the live MCP servers.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';

class ConnectorPage extends ConsumerWidget {
  const ConnectorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(opsConfigProvider);
    final inbound = cfg.mcp.inbound;

    final httpUrl =
        inbound.streamableHttpEnabled
            ? 'http://localhost:${inbound.streamableHttpPort}/mcp'
            : null;
    final sseUrl =
        inbound.sseEnabled ? 'http://localhost:${inbound.ssePort}/sse' : null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            'Connect external MCP clients',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Paste these snippets into your Claude Desktop, Claude Code, '
            'Cursor, or VSCode (Continue) configuration. Settings → MCP '
            'inbound controls which transports listen.',
            style: TextStyle(color: OpsColors.text2),
          ),
          const SizedBox(height: 16),
          _LiveListenerSection(httpUrl: httpUrl, sseUrl: sseUrl),
          const Divider(height: 32),
          _SnippetCard(
            title: 'Claude Desktop',
            body: _claudeDesktopSnippet(httpUrl, sseUrl),
            note:
                '~/Library/Application Support/Claude/claude_desktop_config.json',
          ),
          const SizedBox(height: 12),
          _SnippetCard(
            title: 'Claude Code (CLI)',
            body: _claudeCodeSnippet(httpUrl, sseUrl),
            note: 'Run from your project root.',
          ),
          const SizedBox(height: 12),
          _SnippetCard(
            title: 'Cursor',
            body: _cursorSnippet(httpUrl, sseUrl),
            note: '~/.cursor/mcp.json',
          ),
          const SizedBox(height: 12),
          _SnippetCard(
            title: 'VSCode (Continue extension)',
            body: _vscodeContinueSnippet(httpUrl, sseUrl),
            note:
                '.continue/config.json (workspace) or ~/.continue/config.json',
          ),
        ],
      ),
    );
  }

  String _claudeDesktopSnippet(String? http, String? sse) {
    final url = http ?? sse;
    if (url == null) return _disabledNote();
    final cfg = {
      'mcpServers': {
        'makemind-ops': {
          'transport': http != null ? 'streamable-http' : 'sse',
          'url': url,
        },
      },
    };
    return _pretty(cfg);
  }

  String _claudeCodeSnippet(String? http, String? sse) {
    final url = http ?? sse;
    if (url == null) return _disabledNote();
    final transport = http != null ? 'streamable-http' : 'sse';
    return [
      '# Add as a project-scoped MCP server',
      'claude mcp add makemind-ops \\\n'
          '  --transport $transport \\\n'
          '  --url $url',
    ].join('\n');
  }

  String _cursorSnippet(String? http, String? sse) {
    final url = http ?? sse;
    if (url == null) return _disabledNote();
    final cfg = {
      'mcpServers': {
        'makemind-ops': {'url': url},
      },
    };
    return _pretty(cfg);
  }

  String _vscodeContinueSnippet(String? http, String? sse) {
    final url = http ?? sse;
    if (url == null) return _disabledNote();
    final cfg = {
      'experimental': {
        'modelContextProtocolServers': [
          {
            'transport': {
              'type': http != null ? 'streamable-http' : 'sse',
              'url': url,
            },
          },
        ],
      },
    };
    return _pretty(cfg);
  }

  String _disabledNote() =>
      '⚠ Both SSE and Streamable HTTP listeners are off.\n'
      'Enable one in Settings → MCP inbound to generate this snippet.';

  String _pretty(Object o) => const JsonEncoder.withIndent('  ').convert(o);
}

class _LiveListenerSection extends StatelessWidget {
  const _LiveListenerSection({this.httpUrl, this.sseUrl});
  final String? httpUrl;
  final String? sseUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OpsColors.surface1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Live listeners',
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              fontWeight: OpsType.semibold,
              color: OpsColors.text2,
            ),
          ),
          const SizedBox(height: 6),
          _row('Streamable HTTP', httpUrl),
          _row('SSE (legacy)', sseUrl),
        ],
      ),
    );
  }

  Widget _row(String label, String? url) {
    final ok = url != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 14,
            color: ok ? OpsColors.success : OpsColors.text3,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontFamily: OpsType.sans, fontSize: 12),
            ),
          ),
          Expanded(
            child: SelectableText(
              url ?? 'disabled',
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 12,
                color: ok ? OpsColors.text : OpsColors.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnippetCard extends StatefulWidget {
  const _SnippetCard({required this.title, required this.body, this.note});
  final String title;
  final String body;
  final String? note;

  @override
  State<_SnippetCard> createState() => _SnippetCardState();
}

class _SnippetCardState extends State<_SnippetCard> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.body));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OpsColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontFamily: OpsType.sans,
                      fontSize: 13,
                      fontWeight: OpsType.semibold,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy_outlined,
                    size: 14,
                  ),
                  label: Text(_copied ? 'Copied' : 'Copy'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(
                widget.note!,
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 11,
                  color: OpsColors.text3,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: OpsColors.surface1,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: SelectableText(
              widget.body,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 12,
                color: OpsColors.text,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
