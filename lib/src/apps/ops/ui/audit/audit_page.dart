import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/app_theme.dart' show OpsStatus;
import '../../theme/tokens.dart';
import '../../widgets/ops_atoms.dart';

/// Audit — the tool calls this studio has handled since it started, newest
/// first: when, which tool, how long, whether it failed, with what arguments
/// and what came back. Read from the host's dispatch log
/// (`studio.debug.dispatch_log`), which holds the latest 200 calls in
/// memory; secret argument values arrive already masked.
class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  static const int _limit = 200;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _entries = const [];
  bool _errorsOnly = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await opsCallTool(ref, 'studio.debug.dispatch_log', {
        'limit': _limit,
      });
      if (!mounted) return;
      setState(() {
        _entries =
            ((res['entries'] as List?) ?? const [])
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList()
                .reversed
                .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _visible {
    final needle = _filter.trim().toLowerCase();
    return <Map<String, dynamic>>[
      for (final e in _entries)
        if ((!_errorsOnly || e['isError'] == true) &&
            (needle.isEmpty || '${e['tool']}'.toLowerCase().contains(needle)))
          e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OpsCrumb('System'),
          const SizedBox(height: 4),
          Text('Audit', style: Theme.of(context).textTheme.displayMedium),
          const SizedBox(height: 8),
          Text(
            'Tool calls this studio has handled since it started — the '
            'latest $_limit, newest first. Held in memory only; secret '
            'values are masked.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('audit.filter'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    hintText: 'Filter by tool name',
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                key: const ValueKey('audit.errorsOnly'),
                label: const Text('Errors only'),
                selected: _errorsOnly,
                onSelected: (v) => setState(() => _errorsOnly = v),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _loading ? null : _refresh,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
    final rows = _visible;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          _entries.isEmpty ? 'No tool calls yet.' : 'No calls match.',
          style: TextStyle(color: OpsColors.text3),
        ),
      );
    }
    // Same frame as OpsCard, but the list fills the remaining height and
    // scrolls inside it (OpsCard's column sizes to its content).
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: OpsColors.border),
        borderRadius: OpsRadius.all_md,
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: rows.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => _AuditRow(entry: rows[i]),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});

  final Map<String, dynamic> entry;

  static String _time(Object? ts) {
    final t = DateTime.tryParse('$ts')?.toLocal();
    if (t == null) return '--:--:--';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final failed = entry['isError'] == true;
    final mono = TextStyle(fontFamily: OpsType.mono, fontSize: 12);
    final detail = <String, Object?>{
      if (entry['args'] != null) 'args': entry['args'],
      if (entry['resultPreview'] != null) 'result': entry['resultPreview'],
      if (entry['thrown'] != null) 'thrown': entry['thrown'],
    };
    return ExpansionTile(
      key: ValueKey('audit.row.${entry['ts']}.${entry['tool']}'),
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              _time(entry['ts']),
              style: mono.copyWith(color: OpsColors.text3),
            ),
          ),
          Expanded(
            child: Text(
              '${entry['tool']}',
              style: mono,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '${entry['durationMs'] ?? '-'} ms',
              textAlign: TextAlign.right,
              style: mono.copyWith(color: OpsColors.text3),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Center(
              child: OpsStatusPill(
                status: failed ? OpsStatus.error : OpsStatus.ok,
                label: failed ? 'ERR' : 'OK',
                compact: true,
              ),
            ),
          ),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(detail),
              style: mono.copyWith(fontSize: 11, color: OpsColors.text2),
            ),
          ),
        ),
      ],
    );
  }
}
