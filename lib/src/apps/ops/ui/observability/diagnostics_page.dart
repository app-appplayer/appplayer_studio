// Diagnostics page — telemetry overview + recent activity + diagnostic
// bundle export. PRD §FM-OBSERVE-04 / 05.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../observability/activity_event.dart';
import '../../observability/diagnostic_export.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final obs = ref.watch(observabilityProvider);
    final telemetryAsync = ref.watch(telemetryProvider);
    final eventsAsync = ref.watch(activitySnapshotProvider);
    final telemetry = telemetryAsync.maybeWhen(
      data: (t) => t,
      orElse: () => obs.telemetry,
    );
    final events = eventsAsync.maybeWhen(
      data: (e) => e,
      orElse: () => obs.bus.recent,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Diagnostics',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export bundle (.zip)'),
                onPressed: () => _exportBundle(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _TelemetrySection(),
          const SizedBox(height: 16),
          Text(
            'Recent activity (${events.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'No events yet — interact with the app to populate.',
                  style: TextStyle(color: OpsColors.text3),
                ),
              ),
            )
          else
            for (final e in events.reversed.take(60)) _EventTile(event: e),
          const SizedBox(height: 24),
          Text(
            'Telemetry totals · uptime ${_fmtUptime(telemetry.uptime)}',
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 11,
              color: OpsColors.text3,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBundle(BuildContext context, WidgetRef ref) async {
    final obs = ref.read(observabilityProvider);
    final cfg = ref.read(opsConfigProvider);
    try {
      final bundle = await DiagnosticExport.build(
        observability: obs,
        config: cfg,
      );
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final saveLocation = await getSaveLocation(
        suggestedName: 'makemind-ops-diagnostic-$ts.zip',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'zip', extensions: ['zip']),
        ],
      );
      if (saveLocation == null) return;
      await File(saveLocation.path).writeAsBytes(bundle.bytes);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved diagnostic bundle to ${saveLocation.path}'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  String _fmtUptime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${h}h ${m}m ${s}s';
  }
}

class _TelemetrySection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetryAsync = ref.watch(telemetryProvider);
    final obs = ref.watch(observabilityProvider);
    final t = telemetryAsync.maybeWhen(
      data: (t) => t,
      orElse: () => obs.telemetry,
    );
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _Counter(label: 'LLM calls', value: '${t.totalLlmCalls}'),
        _Counter(label: 'Tokens in', value: '${t.totalTokensIn}'),
        _Counter(label: 'Tokens out', value: '${t.totalTokensOut}'),
        _Counter(
          label: 'Tool dispatches',
          value: '${t.tools.values.fold<int>(0, (a, b) => a + b.calls)}',
        ),
        _Counter(label: 'MCP inbound', value: '${t.mcpInboundRequests}'),
        _Counter(label: 'Agent asks', value: '${t.agentAsks}'),
        _Counter(label: 'Errors', value: '${t.totalLlmErrors}'),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: OpsColors.surface1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OpsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 10,
              color: OpsColors.text3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontFamily: OpsType.mono,
              fontSize: 20,
              fontWeight: OpsType.semibold,
            ),
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final ActivityEvent event;
  @override
  Widget build(BuildContext context) {
    final color = switch (event.severity) {
      ActivitySeverity.error => OpsColors.danger,
      ActivitySeverity.warn => OpsColors.warn,
      ActivitySeverity.info => OpsColors.text2,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OpsColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              _fmtTime(event.ts),
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 11,
                color: OpsColors.text3,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              event.kind.name,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 11,
                color: OpsColors.text3,
              ),
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              event.actor,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 11,
                color: OpsColors.text2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              event.headline,
              style: TextStyle(
                fontFamily: OpsType.sans,
                fontSize: 12,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
