// About / Credits page — surfaces build info, makemind ecosystem links,
// dependency notes, and license. PRD §FM-OBSERVE-04 supporting surface
// (paired with Diagnostics for the support flow).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(opsConfigProvider);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          _Hero(appName: cfg.appName),
          const SizedBox(height: 20),
          _Section(
            title: 'Build',
            child: _PropertyTable(
              rows: [
                _Prop('App name', cfg.appName),
                _Prop('Config version', cfg.version),
                _Prop(
                  'Active workspace',
                  cfg.activeWorkspace.isEmpty ? '—' : cfg.activeWorkspace,
                ),
                _Prop('Workspaces root', cfg.workspacesRoot),
                _Prop('Theme mode', cfg.themeMode),
                _Prop(
                  'Platform',
                  '${Platform.operatingSystem} '
                      '${Platform.operatingSystemVersion}',
                ),
                _Prop('Locale', Platform.localeName),
                _Prop('Dart', Platform.version),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: 'makemind ecosystem',
            child: _Bullets(
              items: [
                'flowbrain — knowledge + agent subsystem (5 facade + AgentRuntime + ForkEngine + GrowthTracker)',
                'mcp_bundle — port hub (50+ ports for LLM / tool / resource / channel / form / browser …)',
                'mcp_server / mcp_client — MCP transport over stdio · SSE · Streamable HTTP',
                'mcp_skill / mcp_profile / mcp_philosophy — 4-axis pool definitions',
                'mcp_fact_graph — typed evidence + relations',
                'mcp_browser — headful Chromium automation for external systems',
                'AppPlayer — companion runtime that lets Ops bundles run as apps without a separate install',
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'License',
            child: Text(
              'makemind Ops is distributed under the makemind workspace '
              'license — review the per-package LICENSE file in the source '
              'tree. Bundled flowbrain, mcp_*, and adapter packages keep '
              'their own license terms.',
              style: TextStyle(
                fontFamily: OpsType.sans,
                fontSize: 12,
                color: OpsColors.text2,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Diagnostics',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.medical_services_outlined, size: 14),
                  label: const Text('Open diagnostics'),
                  onPressed:
                      () =>
                          ref.read(shellRouteProvider.notifier).state =
                              'diagnostics',
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cable_outlined, size: 14),
                  label: const Text('MCP connector helper'),
                  onPressed:
                      () =>
                          ref.read(shellRouteProvider.notifier).state =
                              'connector',
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.import_export_outlined, size: 14),
                  label: const Text('Workspace portability'),
                  onPressed:
                      () =>
                          ref.read(shellRouteProvider.notifier).state =
                              'portability',
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_outlined, size: 14),
                  label: const Text('Copy build info'),
                  onPressed:
                      () => Clipboard.setData(
                        ClipboardData(text: _buildInfoText(cfg)),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _buildInfoText(dynamic cfg) {
    return [
      'makemind Ops',
      'appName: ${cfg.appName}',
      'configVersion: ${cfg.version}',
      'activeWorkspace: ${cfg.activeWorkspace}',
      'platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'dart: ${Platform.version}',
    ].join('\n');
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.appName});
  final String appName;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [OpsColors.protocol, OpsColors.knowledge],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            appName,
            style: const TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 22,
              fontWeight: OpsType.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Knowledge + agents on your desktop. Free distribution showcase '
            'of the makemind ecosystem.',
            style: TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 13,
              color: Colors.white,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: OpsType.sans,
              fontSize: 13,
              fontWeight: OpsType.semibold,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _PropertyTable extends StatelessWidget {
  const _PropertyTable({required this.rows});
  final List<_Prop> rows;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 140,
                  child: Text(
                    r.label,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 11,
                      color: OpsColors.text3,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    r.value,
                    style: TextStyle(
                      fontFamily: OpsType.mono,
                      fontSize: 12,
                      color: OpsColors.text2,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Prop {
  const _Prop(this.label, this.value);
  final String label;
  final String value;
}

class _Bullets extends StatelessWidget {
  const _Bullets({required this.items});
  final List<String> items;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 6, right: 8),
                  child: Icon(Icons.circle, size: 5, color: OpsColors.text3),
                ),
                Expanded(
                  child: Text(
                    s,
                    style: TextStyle(
                      fontFamily: OpsType.sans,
                      fontSize: 12,
                      color: OpsColors.text2,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
