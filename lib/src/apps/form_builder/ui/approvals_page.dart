/// 결재함 — the approval inbox/progress view.
///
/// Two bands over the same `form_approval` facts: gates WAITING on someone
/// (act here — approve/전결/reject, acting as the gate's designated
/// approver) and everything else latest-first (line progress ● ○ ✕ ⤵).
/// Button = tool, 1:1: every mutation goes through `form_builder.approve` /
/// `form_builder.reject` — exactly what an external LLM drives. Design:
/// `docs/form_builder/form-approval-line.md`.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;

import '../init/form_init.dart';
import 'form_tool_client.dart';

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key, required this.server, required this.init});

  final BuiltinToolRegistry server;
  final FormInit init;

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  List<Map<String, dynamic>> _approvals = const [];
  bool _loading = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final approvals = await widget.init.listApprovals();
    if (!mounted) return;
    setState(() {
      _approvals = approvals;
      _loading = false;
    });
  }

  Future<void> _act(
    Map<String, dynamic> approval, {
    required bool approve,
  }) async {
    final line = (approval['line'] as List).cast<Map>();
    final gate = line[approval['currentIndex'] as int];
    final actor = gate['approverId'] as String;
    final commentCtrl = TextEditingController();
    var finalize = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            approve ? 'Approve — $actor' : 'Reject — $actor',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${approval['title'] ?? approval['documentId']}'
                ' · 기안 ${approval['requestedBy']}',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: commentCtrl,
                decoration: InputDecoration(
                  labelText: approve ? 'Comment (optional)' : '반려 사유 (필수)',
                  border: const OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              if (approve)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('전결 — 잔여 결재 생략하고 완결'),
                  value: finalize,
                  onChanged: (v) =>
                      setDialogState(() => finalize = v ?? false),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(approve ? 'Approve' : 'Reject'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      if (approve) {
        await callFormTool(widget.server, 'form_builder.approve', {
          'documentId': approval['documentId'],
          'actor': actor,
          if (commentCtrl.text.trim().isNotEmpty)
            'comment': commentCtrl.text.trim(),
          if (finalize) 'finalize': true,
        });
      } else {
        await callFormTool(widget.server, 'form_builder.reject', {
          'documentId': approval['documentId'],
          'actor': actor,
          'comment': commentCtrl.text.trim(),
        });
      }
      _notice = null;
    } on FormToolException catch (e) {
      _notice = e.message;
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final pending =
        _approvals.where((a) => a['state'] == 'pending').toList();
    final done = _approvals.where((a) => a['state'] != 'pending').toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Approvals',
                style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
          ],
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _notice!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_approvals.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '기안이 없습니다 — Compose에서 드래프트를 저장한 뒤 '
              'Request approval 로 상신하세요.',
            ),
          ),
        if (pending.isNotEmpty) ...[
          const _BandHeader('결재 대기'),
          for (final a in pending) _card(a, actionable: true),
        ],
        if (done.isNotEmpty) ...[
          const _BandHeader('완결·반려·철회'),
          for (final a in done) _card(a, actionable: false),
        ],
      ],
    );
  }

  Widget _card(Map<String, dynamic> a, {required bool actionable}) {
    final line = (a['line'] as List).cast<Map>();
    final state = a['state'] as String;
    final gate = state == 'pending'
        ? line[a['currentIndex'] as int]['approverId']
        : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${a['title'] ?? a['documentId']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _StateChip(state),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '기안 ${a['requestedBy']} · ${a['requestedAt'] ?? ''}'
              '${gate != null ? ' · 현재 결재자 $gate' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in line)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Text(_mark(e['status'] as String? ?? 'pending')),
                    label: Text(
                      '${e['approverId']}'
                      '${e['roleLabel'] != null ? ' (${e['roleLabel']})' : ''}'
                      '${e['comment'] != null ? ' — ${e['comment']}' : ''}',
                    ),
                  ),
              ],
            ),
            if (actionable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => _act(a, approve: false),
                      child: const Text('Reject'),
                    ),
                    FilledButton(
                      onPressed: () => _act(a, approve: true),
                      child: const Text('Approve'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _mark(String status) => switch (status) {
        'approved' => '●',
        'rejected' => '✕',
        'skipped' => '⤵',
        _ => '○',
      };
}

class _BandHeader extends StatelessWidget {
  const _BandHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(letterSpacing: 1.1),
        ),
      );
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state);

  final String state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (state) {
      'approved' => ('approved', scheme.primary),
      'rejected' => ('rejected', scheme.error),
      'withdrawn' => ('withdrawn', scheme.outline),
      _ => ('pending', scheme.tertiary),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
      side: BorderSide(color: color),
      labelStyle: TextStyle(color: color),
    );
  }
}
