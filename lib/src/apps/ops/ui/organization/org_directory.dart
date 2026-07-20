/// Organization DIRECTORY — the card master-detail view (default lens).
///
/// Three panes: a units/workflows nav list on the left, an indented card
/// tree in the center (unit header rows + member cards, collapse carets,
/// live overlay signals), and a property panel on the right for whatever
/// is selected (member edit through the real tool surface, unit summary
/// with lead assignment, process summary). A stats strip runs along the
/// bottom. The painted canvas stays available as the Chart toggle.
/// Design: `docs/makemind_ops/org-directory-master-detail.md`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';
import 'org_chart_model.dart';
import 'org_overlay.dart';

/// Selection = (kind, id) — member 'ws|agentId', unit 'wsId', process 'wsId|procId'.
enum OrgSelKind { member, unit, process }

class OrgSelection {
  const OrgSelection(this.kind, this.wsId, [this.itemId]);
  final OrgSelKind kind;
  final String wsId;
  final String? itemId;

  @override
  bool operator ==(Object other) =>
      other is OrgSelection &&
      other.kind == kind &&
      other.wsId == wsId &&
      other.itemId == itemId;

  @override
  int get hashCode => Object.hash(kind, wsId, itemId);
}

class OrgDirectory extends ConsumerStatefulWidget {
  const OrgDirectory({super.key, required this.inputs, this.overlay});

  final List<OrgWsInput> inputs;
  final OrgChartOverlay? overlay;

  @override
  ConsumerState<OrgDirectory> createState() => _OrgDirectoryState();
}

class _OrgDirectoryState extends ConsumerState<OrgDirectory> {
  OrgSelection? _sel;
  final Set<String> _collapsed = <String>{};

  // Avatar palette — name-hash stable, matches the reference look.
  static const _avatarColors = <Color>[
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF8B5CF6),
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFFA3E635),
  ];

  Color _avatarColor(String name) =>
      _avatarColors[name.hashCode.abs() % _avatarColors.length];

  Map<String, List<OrgWsInput>> get _children {
    final m = <String, List<OrgWsInput>>{};
    for (final w in widget.inputs) {
      final pid = w.parentId;
      if (pid != null && pid.isNotEmpty) (m[pid] ??= []).add(w);
    }
    for (final l in m.values) {
      l.sort(orgWsSiblingCompare);
    }
    return m;
  }

  List<OrgWsInput> get _roots {
    final ids = {for (final w in widget.inputs) w.id};
    return [
      for (final w in widget.inputs)
        if (w.parentId == null ||
            w.parentId!.isEmpty ||
            !ids.contains(w.parentId))
          w,
    ]..sort(orgWsSiblingCompare);
  }

  int get _depth {
    final kids = _children;
    int walk(OrgWsInput w) {
      final c = kids[w.id] ?? const [];
      var mx = 1;
      for (final k in c) {
        final d = walk(k) + 1;
        if (d > mx) mx = d;
      }
      return mx;
    }

    var mx = 0;
    for (final r in _roots) {
      final d = walk(r);
      if (d > mx) mx = d;
    }
    return mx;
  }

  OrgWsInput? _ws(String id) {
    for (final w in widget.inputs) {
      if (w.id == id) return w;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.inputs.fold<int>(0, (a, w) => a + w.agents.length);
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NavList(
                inputs: widget.inputs,
                roots: _roots,
                childrenOf: _children,
                selected: _sel,
                onSelect: (s) => setState(() => _sel = s),
              ),
              VerticalDivider(width: 1, color: OpsColors.border),
              Expanded(child: _cardTree()),
              if (_sel != null) ...[
                VerticalDivider(width: 1, color: OpsColors.border),
                SizedBox(
                  width: 300,
                  child: _PropertyPanel(
                    key: ValueKey(_sel),
                    sel: _sel!,
                    ws: _ws(_sel!.wsId),
                    inputs: widget.inputs,
                    onClose: () => setState(() => _sel = null),
                    onChanged: () => ref.invalidate(orgChartInputsProvider),
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: OpsColors.border),
        _statsStrip(total),
      ],
    );
  }

  Widget _statsStrip(int total) {
    Widget stat(String label, String value) => Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: OpsType.xs, color: OpsColors.text3),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: OpsType.sm,
              fontWeight: OpsType.semibold,
              fontFamily: OpsType.mono,
              color: OpsColors.text,
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          stat('Members', '$total'),
          stat('Units', '${widget.inputs.length}'),
          stat('Depth', '$_depth'),
        ],
      ),
    );
  }

  // --- center card tree ---

  Widget _cardTree() {
    final rows = <Widget>[];
    void emitUnit(OrgWsInput w, int indent) {
      rows.add(_unitRow(w, indent));
      if (!_collapsed.contains(w.id)) {
        final leadKey = w.leadMemberId;
        final agents = [...w.agents]..sort((a, b) {
          final al = a.memberKey == leadKey ? 0 : 1;
          final bl = b.memberKey == leadKey ? 0 : 1;
          final c = al.compareTo(bl);
          return c != 0 ? c : a.displayName.compareTo(b.displayName);
        });
        for (final a in agents) {
          rows.add(
            _memberCard(w, a, indent + 1, isLead: a.memberKey == leadKey),
          );
        }
        for (final k in (_children[w.id] ?? const <OrgWsInput>[])) {
          emitUnit(k, indent + 1);
        }
      }
    }

    for (final r in _roots) {
      emitUnit(r, 0);
    }
    if (rows.isEmpty) {
      return const Center(child: Text('No units yet.'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: rows,
    );
  }

  Widget _unitRow(OrgWsInput w, int indent) {
    final collapsed = _collapsed.contains(w.id);
    final selected = _sel?.kind == OrgSelKind.unit && _sel?.wsId == w.id;
    final pending = widget.overlay?.pendingByUnit[w.id] ?? 0;
    return Padding(
      padding: EdgeInsets.only(left: indent * 26.0, top: 10, bottom: 2),
      child: InkWell(
        borderRadius: OpsRadius.all_md,
        onTap: () => setState(() => _sel = OrgSelection(OrgSelKind.unit, w.id)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: OpsRadius.all_md,
            border:
                selected
                    ? Border.all(color: OpsColors.domain, width: 1.2)
                    : null,
            color: OpsColors.domain.withValues(alpha: 0.06),
          ),
          child: Row(
            children: [
              InkWell(
                onTap:
                    () => setState(() {
                      collapsed
                          ? _collapsed.remove(w.id)
                          : _collapsed.add(w.id);
                    }),
                child: Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                  color: OpsColors.text2,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _avatarColor(w.title),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                w.title,
                style: TextStyle(
                  fontSize: OpsType.md,
                  fontWeight: OpsType.semibold,
                  color: OpsColors.text,
                ),
              ),
              const SizedBox(width: 8),
              _chip(w.type, OpsColors.domain),
              if (pending > 0) ...[
                const SizedBox(width: 6),
                _chip('⏳ $pending', OpsColors.warn),
              ],
              const Spacer(),
              Text(
                '${w.agents.length}',
                style: TextStyle(
                  fontSize: OpsType.xs,
                  fontFamily: OpsType.mono,
                  color: OpsColors.text3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _memberCard(
    OrgWsInput w,
    OrgAgentInput a,
    int indent, {
    required bool isLead,
  }) {
    final selected =
        _sel?.kind == OrgSelKind.member &&
        _sel?.wsId == w.id &&
        _sel?.itemId == a.agentId;
    final active =
        widget.overlay?.activeNodeIds.contains('ag:${w.id}:${a.agentId}') ??
        false;
    final color = _avatarColor(a.displayName);
    final initial =
        a.displayName.isEmpty ? '?' : a.displayName.characters.first;
    return Padding(
      padding: EdgeInsets.only(left: indent * 26.0, top: 6),
      child: InkWell(
        borderRadius: OpsRadius.all_md,
        onTap:
            () => setState(
              () => _sel = OrgSelection(OrgSelKind.member, w.id, a.agentId),
            ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: OpsRadius.all_md,
            color: OpsColors.surface.withValues(alpha: 0.5),
            border: Border.all(
              color:
                  selected
                      ? OpsColors.app
                      : OpsColors.border.withValues(alpha: 0.7),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: color.withValues(alpha: 0.9),
                    child: Text(
                      initial,
                      style: TextStyle(
                        fontSize: OpsType.md,
                        fontWeight: OpsType.semibold,
                        color: Colors.black.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                  if (active)
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: OpsColors.success,
                          border: Border.all(
                            color: OpsColors.surface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            a.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: OpsType.md,
                              fontWeight: OpsType.medium,
                              color: OpsColors.text,
                            ),
                          ),
                        ),
                        if (isLead) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.star, size: 13, color: OpsColors.domain),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${a.role.isEmpty ? 'member' : a.role} · '
                      '${a.isAgent ? 'agent' : 'human'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: OpsType.xs,
                        fontFamily: OpsType.mono,
                        color: OpsColors.text3,
                      ),
                    ),
                  ],
                ),
              ),
              _chip(w.title, _avatarColor(w.title)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      borderRadius: OpsRadius.all_md,
      border: Border.all(color: color.withValues(alpha: 0.6)),
      color: color.withValues(alpha: 0.10),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: OpsType.xs,
        fontFamily: OpsType.mono,
        color: color,
      ),
    ),
  );
}

// --- left nav ---

class _NavList extends StatelessWidget {
  const _NavList({
    required this.inputs,
    required this.roots,
    required this.childrenOf,
    required this.selected,
    required this.onSelect,
  });

  final List<OrgWsInput> inputs;
  final List<OrgWsInput> roots;
  final Map<String, List<OrgWsInput>> childrenOf;
  final OrgSelection? selected;
  final ValueChanged<OrgSelection> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Text(
        t,
        style: TextStyle(
          fontSize: OpsType.xs,
          fontFamily: OpsType.mono,
          letterSpacing: OpsType.mono06,
          color: OpsColors.textMute,
        ),
      ),
    );
    Widget row({
      required String label,
      required bool isSelected,
      required VoidCallback onTap,
      String? count,
      int indent = 0,
    }) => InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? OpsColors.app.withValues(alpha: 0.10) : null,
        padding: EdgeInsets.only(
          left: 14.0 + indent * 14,
          right: 14,
          top: 5,
          bottom: 5,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: OpsType.sm,
                  color: isSelected ? OpsColors.app : OpsColors.text2,
                  fontWeight: isSelected ? OpsType.semibold : FontWeight.w400,
                ),
              ),
            ),
            if (count != null)
              Text(
                count,
                style: TextStyle(
                  fontSize: OpsType.xs,
                  fontFamily: OpsType.mono,
                  color: OpsColors.textMute,
                ),
              ),
          ],
        ),
      ),
    );

    final unitRows = <Widget>[];
    void emit(OrgWsInput w, int indent) {
      unitRows.add(
        row(
          label: w.title,
          count: '${w.agents.length}',
          indent: indent,
          isSelected:
              selected?.kind == OrgSelKind.unit && selected?.wsId == w.id,
          onTap: () => onSelect(OrgSelection(OrgSelKind.unit, w.id)),
        ),
      );
      for (final k in (childrenOf[w.id] ?? const <OrgWsInput>[])) {
        emit(k, indent + 1);
      }
    }

    for (final r in roots) {
      emit(r, 0);
    }

    return SizedBox(
      width: 200,
      child: ListView(
        children: [
          header('UNITS'),
          ...unitRows,
          header('WORKFLOWS'),
          for (final w in inputs)
            for (final p in w.processes)
              row(
                label: p.title,
                isSelected:
                    selected?.kind == OrgSelKind.process &&
                    selected?.wsId == w.id &&
                    selected?.itemId == p.id,
                onTap:
                    () =>
                        onSelect(OrgSelection(OrgSelKind.process, w.id, p.id)),
              ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// --- right property panel ---

class _PropertyPanel extends ConsumerStatefulWidget {
  const _PropertyPanel({
    super.key,
    required this.sel,
    required this.ws,
    required this.inputs,
    required this.onClose,
    required this.onChanged,
  });

  final OrgSelection sel;
  final OrgWsInput? ws;
  final List<OrgWsInput> inputs;
  final VoidCallback onClose;
  final VoidCallback onChanged;

  @override
  ConsumerState<_PropertyPanel> createState() => _PropertyPanelState();
}

class _PropertyPanelState extends ConsumerState<_PropertyPanel> {
  late final TextEditingController _name;
  late final TextEditingController _role;
  String? _status;

  OrgAgentInput? get _member {
    if (widget.sel.kind != OrgSelKind.member) return null;
    for (final a in widget.ws?.agents ?? const <OrgAgentInput>[]) {
      if (a.agentId == widget.sel.itemId) return a;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final m = _member;
    _name = TextEditingController(text: m?.displayName ?? '');
    _role = TextEditingController(text: m?.role ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _role.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = _member;
    if (m == null) return;
    setState(() => _status = 'saving…');
    try {
      final id = m.memberId ?? m.agentId;
      // The card's "role" is the member's free-text role TAG (the
      // member_update `role` arg is the orchestration enum — different
      // axis), and the registry REPLACES tags wholesale — so read the
      // current tags first and merge.
      final cur = await opsCallTool(ref, 'member_get', {
        'id': id,
        'workspaceId': widget.sel.wsId,
      });
      final tags = <String, dynamic>{
        ...?(cur['tags'] as Map?)?.cast<String, dynamic>(),
        'role': _role.text.trim(),
      };
      final res = await opsCallTool(ref, 'member_update', {
        'id': id,
        'workspaceId': widget.sel.wsId,
        'displayName': _name.text.trim(),
        'tags': tags,
      });
      // Some handlers report failure as {'error': …} content instead of
      // an MCP error — surface it instead of a fake "saved".
      if (res['error'] != null) throw StateError('${res['error']}');
      widget.onChanged();
      if (mounted) setState(() => _status = 'saved');
    } catch (e) {
      if (mounted) setState(() => _status = 'save failed: $e');
    }
  }

  Future<void> _delete() async {
    final m = _member;
    if (m == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete member'),
            content: Text('Remove "${m.displayName}" from this unit?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    setState(() => _status = 'deleting…');
    try {
      final res = await opsCallTool(ref, 'member_delete', {
        'id': m.memberId ?? m.agentId,
        'workspaceId': widget.sel.wsId,
      });
      if (res['error'] != null) throw StateError('${res['error']}');
      widget.onChanged();
      widget.onClose();
    } catch (e) {
      if (mounted) setState(() => _status = 'delete failed: $e');
    }
  }

  /// Reporting chain: this member ← unit lead ← parent unit lead ← …
  List<String> get _reportingChain {
    final chain = <String>[];
    var ws = widget.ws;
    final byId = {for (final w in widget.inputs) w.id: w};
    while (ws != null) {
      final leadKey = ws.leadMemberId;
      if (leadKey != null && leadKey.isNotEmpty) {
        for (final a in ws.agents) {
          if (a.memberKey == leadKey) {
            chain.add('${a.displayName} (${ws.title})');
            break;
          }
        }
      }
      ws = ws.parentId != null ? byId[ws.parentId] : null;
    }
    return chain;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                switch (widget.sel.kind) {
                  OrgSelKind.member => 'Member',
                  OrgSelKind.unit => 'Unit',
                  OrgSelKind.process => 'Workflow',
                },
                style: TextStyle(
                  fontSize: OpsType.xs,
                  fontFamily: OpsType.mono,
                  letterSpacing: OpsType.mono06,
                  color: OpsColors.textMute,
                ),
              ),
            ),
            InkWell(
              onTap: widget.onClose,
              child: Icon(Icons.close, size: 18, color: OpsColors.text3),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...switch (widget.sel.kind) {
          OrgSelKind.member => _memberBody(),
          OrgSelKind.unit => _unitBody(),
          OrgSelKind.process => _processBody(),
        },
      ],
    );
  }

  List<Widget> _memberBody() {
    final m = _member;
    if (m == null) return [const Text('Member not found.')];
    final chain = _reportingChain;
    return [
      Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor:
                _OrgDirectoryState._avatarColors[m.displayName.hashCode.abs() %
                    _OrgDirectoryState._avatarColors.length],
            child: Text(
              m.displayName.isEmpty ? '?' : m.displayName.characters.first,
              style: TextStyle(
                fontSize: OpsType.lg,
                fontWeight: OpsType.semibold,
                color: Colors.black.withValues(alpha: 0.75),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.displayName,
                  style: TextStyle(
                    fontSize: OpsType.lg,
                    fontWeight: OpsType.semibold,
                    color: OpsColors.text,
                  ),
                ),
                Text(
                  '${m.role.isEmpty ? 'member' : m.role} · '
                  '${widget.ws?.title ?? ''}',
                  style: TextStyle(
                    fontSize: OpsType.xs,
                    fontFamily: OpsType.mono,
                    color: OpsColors.text3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      if (chain.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          'Reports through: ${chain.join(' › ')}',
          style: TextStyle(fontSize: OpsType.xs, color: OpsColors.protocol),
        ),
      ],
      const SizedBox(height: 16),
      _field('Name', _name),
      _field('Role', _role),
      _readonly('Kind', m.isAgent ? 'agent' : 'human'),
      if (m.profileRef != null) _readonly('Profile', m.profileRef!),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _delete,
              style: OutlinedButton.styleFrom(
                foregroundColor: OpsColors.danger,
              ),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
      if (_status != null) ...[
        const SizedBox(height: 10),
        Text(
          _status!,
          style: TextStyle(
            fontSize: OpsType.xs,
            fontFamily: OpsType.mono,
            color:
                _status!.contains('failed')
                    ? OpsColors.danger
                    : OpsColors.text3,
          ),
        ),
      ],
    ];
  }

  List<Widget> _unitBody() {
    final w = widget.ws;
    if (w == null) return [const Text('Unit not found.')];
    OrgAgentInput? lead;
    for (final a in w.agents) {
      if (a.memberKey == w.leadMemberId) lead = a;
    }
    return [
      Text(
        w.title,
        style: TextStyle(
          fontSize: OpsType.lg,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: 12),
      _readonly('Type', w.type),
      _readonly('Members', '${w.agents.length}'),
      _readonly('Lead', lead?.displayName ?? '— none set'),
      _readonly('Workflows', '${w.processes.length}'),
    ];
  }

  List<Widget> _processBody() {
    OrgProcessInput? proc;
    for (final p in widget.ws?.processes ?? const <OrgProcessInput>[]) {
      if (p.id == widget.sel.itemId) proc = p;
    }
    if (proc == null) return [const Text('Workflow not found.')];
    return [
      Text(
        proc.title,
        style: TextStyle(
          fontSize: OpsType.lg,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      const SizedBox(height: 12),
      _readonly('Trigger', proc.trigger ?? 'manual'),
      _readonly('Steps', '${proc.steps.length}'),
      _readonly('Gates', '${proc.gates.length}'),
      const SizedBox(height: 8),
      for (final s in proc.steps)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '• ${s.assigneeLabel}${s.skillId.isEmpty ? '' : ' — ${s.skillId}'}',
            style: TextStyle(fontSize: OpsType.sm, color: OpsColors.text2),
          ),
        ),
    ];
  }

  Widget _field(String label, TextEditingController c) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      style: TextStyle(fontSize: OpsType.sm, color: OpsColors.text),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _readonly(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: TextStyle(fontSize: OpsType.xs, color: OpsColors.text3),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: OpsType.sm,
              fontFamily: OpsType.mono,
              color: OpsColors.text2,
            ),
          ),
        ),
      ],
    ),
  );
}
