/// Approval inbox — the approval progress view.
///
/// Two bands over the same `form_approval` facts: gates WAITING on someone
/// (act here — approve/finalize/reject, acting as the gate's designated
/// approver) and everything else latest-first (line progress ● ○ ✕ ⤵).
/// Button = tool, 1:1: every mutation goes through `form_builder.approve` /
/// `form_builder.reject` — exactly what an external LLM drives. Design:
/// `docs/form_builder/form-approval-line.md`.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart'
    show ScopedDialogs, BuiltinToolRegistry, VibeTokens, vibeMono;

import '../init/form_init.dart';
import 'form_tool_client.dart';

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({
    super.key,
    required this.server,
    required this.init,
    this.landingDocumentId,
  });

  final BuiltinToolRegistry server;
  final FormInit init;

  /// Deep-link focus (`studio.app.open … route:approvals entity:<docId>`):
  /// the approval card to accent so the linked item is findable at a
  /// glance in a long inbox.
  final String? landingDocumentId;

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> with ScopedDialogs {
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
    final confirmed = await showScopedDialog<bool>(
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setDialogState) => AlertDialog(
                  title: Text(approve ? 'Approve — $actor' : 'Reject — $actor'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${approval['title'] ?? approval['documentId']}'
                        ' · requested by ${approval['requestedBy']}',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: commentCtrl,
                        decoration: InputDecoration(
                          labelText:
                              approve
                                  ? 'Comment (optional)'
                                  : 'Reason (required)',
                          border: const OutlineInputBorder(),
                        ),
                        maxLines: 2,
                      ),
                      if (approve)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Finalize — skip remaining gates and complete',
                          ),
                          value: finalize,
                          onChanged:
                              (v) =>
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
    final pending = _approvals.where((a) => a['state'] == 'pending').toList();
    final done = _approvals.where((a) => a['state'] != 'pending').toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Approvals', style: Theme.of(context).textTheme.titleLarge),
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
              style: TextStyle(color: VibeTokens.colorOf(context).coral),
            ),
          ),
        if (_approvals.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No approvals yet — save a draft in Compose, then '
              'Request approval.',
            ),
          ),
        if (pending.isNotEmpty) ...[
          const _BandHeader('WAITING'),
          for (final a in pending) _card(a, actionable: true),
        ],
        if (done.isNotEmpty) ...[
          const _BandHeader('COMPLETED · REJECTED · WITHDRAWN'),
          for (final a in done) _card(a, actionable: false),
        ],
      ],
    );
  }

  Widget _card(Map<String, dynamic> a, {required bool actionable}) {
    final line = (a['line'] as List).cast<Map>();
    final state = a['state'] as String;
    final gate =
        state == 'pending'
            ? line[a['currentIndex'] as int]['approverId']
            : null;
    final linked = a['documentId'] == widget.landingDocumentId;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape:
          linked
              ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: VibeTokens.colorOf(context).mint,
                  width: 1.4,
                ),
              )
              : null,
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
              'requested by ${a['requestedBy']} · ${a['requestedAt'] ?? ''}'
              '${gate != null ? ' · current gate $gate' : ''}',
              style: vibeMono(
                size: 11,
                color: VibeTokens.colorOf(context).textSecondary,
              ),
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
      style: vibeMono(
        size: 11,
        color: VibeTokens.colorOf(context).textTertiary,
      ).copyWith(letterSpacing: 1.4),
    ),
  );
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state);

  final String state;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final (label, color) = switch (state) {
      'approved' => ('approved', c.mint),
      'rejected' => ('rejected', c.coral),
      'withdrawn' => ('withdrawn', c.textMuted),
      _ => ('pending', c.amber),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label, style: vibeMono(size: 11, color: color)),
      side: BorderSide(color: color.withValues(alpha: 0.7)),
    );
  }
}
