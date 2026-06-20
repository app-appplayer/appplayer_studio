/// Agents editor for a bundle's `manifest.agents.agents[]`. Panel + detail
/// layout — left column lists agents (id · role chip), click any row to
/// view / edit its detail in the right pane.
///
/// Lifted out of `BundleKnowledgeView` (where agents were one of nine
/// surfaces) into a standalone view so the unified builder's Bundle
/// mode can render agents on its own card alongside Manifest / Tools /
/// Knowledge.
///
/// Writes flow through the same `McpBundleMutator.mutate` transactional
/// authoring path the chat / MCP mutators use (Phase A) — schema
/// validation, in-process mutex, and optimistic checksum guards apply.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/ui.dart';

class BundleAgentsView extends StatefulWidget {
  const BundleAgentsView({
    super.key,
    required this.bundlePath,
    this.reloadCounter = 0,
  });

  final String bundlePath;
  final int reloadCounter;

  @override
  State<BundleAgentsView> createState() => _BundleAgentsViewState();
}

class _BundleAgentsViewState extends State<BundleAgentsView> {
  List<Map<String, dynamic>> _agents = const <Map<String, dynamic>>[];
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BundleAgentsView old) {
    super.didUpdateWidget(old);
    if (old.bundlePath != widget.bundlePath ||
        old.reloadCounter != widget.reloadCounter) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final f = File(p.join(widget.bundlePath, 'manifest.json'));
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final m =
          (mk.McpBundleLoader.fromJsonString(
            raw,
            options: const mk.McpLoaderOptions.lenient(),
          )).toJson();
      final agents = <Map<String, dynamic>>[];
      final agentsBlock = m['agents'];
      if (agentsBlock is Map) {
        final list = agentsBlock['agents'];
        if (list is List) {
          for (final e in list) {
            if (e is Map) agents.add(Map<String, dynamic>.from(e));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _agents = agents;
        if (_selected >= agents.length) _selected = agents.isEmpty ? -1 : 0;
      });
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _patchAgent(int idx, Map<String, dynamic> patch) async {
    try {
      await mk.McpBundleMutator.mutate<bool>(
        widget.bundlePath,
        options: const mk.McpLoaderOptions.lenient(),
        fn: (current) async {
          final raw = current.toJson();
          final agentsBlock = raw['agents'];
          List<dynamic>? list;
          if (agentsBlock is Map) {
            final l = agentsBlock['agents'];
            if (l is List) list = l;
          }
          if (list == null || idx < 0 || idx >= list.length) {
            return mk.MutationOutcome<bool>(result: false);
          }
          final cur = list[idx];
          if (cur is! Map) {
            return mk.MutationOutcome<bool>(result: false);
          }
          list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
          final updated = mk.McpBundleLoader.fromJson(
            raw,
            options: const mk.McpLoaderOptions.lenient(),
          );
          return mk.MutationOutcome<bool>(updated: updated, result: true);
        },
      );
    } catch (_) {
      /* swallow — keep UI responsive */
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 260,
            child: Container(
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: c.borderDefault)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[_header(), Expanded(child: _list())],
              ),
            ),
          ),
          Expanded(child: _detail()),
        ],
      ),
    );
  }

  Widget _header() {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VbuTokens.space3,
        VbuTokens.space3,
        VbuTokens.space3,
        VbuTokens.space2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'AGENTS · ${_agents.length}',
              style: vbuMono(
                size: 11,
                weight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
          ),
          Tooltip(
            message:
                'Add via chat — studio.builder.addKnowledge(kind: '
                '"agent", entry: {id, name, role, ...}).',
            child: Icon(Icons.info_outline, size: 13, color: c.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    final c = VbuTokens.colorOf(context);
    if (_agents.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(VbuTokens.space3),
        child: Text(
          'No agents declared. Use chat to add an agent — '
          'id + role + systemPrompt + model fields required.',
          style: vbuMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    return ListView.builder(
      itemCount: _agents.length,
      itemBuilder: (context, i) {
        final a = _agents[i];
        final id = a['id']?.toString() ?? '(no id)';
        final role = a['role']?.toString() ?? '';
        final isSel = i == _selected;
        return InkWell(
          onTap: () => setState(() => _selected = i),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space3,
              vertical: VbuTokens.space2,
            ),
            decoration: BoxDecoration(
              color: isSel ? c.surface3 : Colors.transparent,
              border: Border(
                bottom: BorderSide(color: c.borderSubtle, width: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  id,
                  style: vbuMono(
                    size: 11,
                    weight: FontWeight.w500,
                    color: isSel ? c.textPrimary : c.textSecondary,
                  ),
                ),
                if (role.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(role, style: vbuMono(size: 10, color: c.textTertiary)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detail() {
    final c = VbuTokens.colorOf(context);
    if (_selected < 0 || _selected >= _agents.length) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(VbuTokens.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.person_outline, size: 28, color: c.textTertiary),
              const SizedBox(height: VbuTokens.space2),
              Text(
                'Pick an agent on the left.',
                style: vbuMono(size: 11, color: c.textTertiary),
              ),
            ],
          ),
        ),
      );
    }
    return _AgentDetailPane(
      key: ValueKey('agent-detail::${_agents[_selected]['id']}'),
      entry: _agents[_selected],
      onUpdate: (patch) => _patchAgent(_selected, patch),
    );
  }
}

class _AgentDetailPane extends StatefulWidget {
  const _AgentDetailPane({
    super.key,
    required this.entry,
    required this.onUpdate,
  });

  final Map<String, dynamic> entry;
  final void Function(Map<String, dynamic>) onUpdate;

  @override
  State<_AgentDetailPane> createState() => _AgentDetailPaneState();
}

class _AgentDetailPaneState extends State<_AgentDetailPane> {
  late TextEditingController _name;
  late TextEditingController _systemPrompt;
  Timer? _save;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.entry['name']?.toString() ?? '')
      ..addListener(_schedule);
    _systemPrompt = TextEditingController(
      text: widget.entry['systemPrompt']?.toString() ?? '',
    )..addListener(_schedule);
  }

  void _schedule() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 300), () {
      widget.onUpdate(<String, dynamic>{
        'name': _name.text,
        'systemPrompt': _systemPrompt.text,
      });
    });
  }

  @override
  void dispose() {
    _save?.cancel();
    _name.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final id = widget.entry['id']?.toString() ?? '';
    final role = widget.entry['role']?.toString() ?? '';
    final model = widget.entry['model'];
    String modelLabel = '';
    if (model is Map) {
      final prov = model['provider']?.toString() ?? '';
      final mname = model['model']?.toString() ?? '';
      modelLabel = (prov.isEmpty && mname.isEmpty) ? '' : '$prov · $mname';
    }
    final toolNames = widget.entry['toolNames'];
    final toolsLabel =
        (toolNames is List && toolNames.isNotEmpty)
            ? toolNames.join(' · ')
            : '(none)';

    // CONNECTIONS — agents compose knowledge categories. Each list
    // surfaces the entry's reference into one of the bundle's knowledge
    // sections, so the user reads the agent as "this manager assembles
    // these skills + these profiles + these philosophies + these
    // sources". IDs only for now (full picker = follow-up).
    List<String> idList(String key) {
      final v = widget.entry[key];
      if (v is! List) return const <String>[];
      return v.map((e) => e.toString()).toList();
    }

    final skills = idList('skillIds');
    final profiles = idList('profileIds');
    final philosophies = idList('philosophyIds');
    final sources = idList('factSourceIds');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Text(
                  role.isEmpty ? 'role: —' : 'role: $role',
                  style: vbuMono(size: 10, color: c.mintDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: VbuTokens.space4),
          _readOnlyRow('id', id),
          _readOnlyRow('model', modelLabel),
          _readOnlyRow('toolNames', toolsLabel),
          const SizedBox(height: VbuTokens.space4),
          _connectionsBlock(
            title: 'CONNECTIONS',
            subtitle:
                'The agent composes these knowledge entries — IDs '
                'reference the bundle\'s knowledge.{skills, profiles, '
                'philosophy.philosophies, sources}.',
            sections: <_AgentConnectionSection>[
              _AgentConnectionSection(
                label: 'skills',
                ids: skills,
                manifestPath: 'skillIds',
              ),
              _AgentConnectionSection(
                label: 'profiles',
                ids: profiles,
                manifestPath: 'profileIds',
              ),
              _AgentConnectionSection(
                label: 'philosophies',
                ids: philosophies,
                manifestPath: 'philosophyIds',
              ),
              _AgentConnectionSection(
                label: 'sources',
                ids: sources,
                manifestPath: 'factSourceIds',
              ),
            ],
          ),
          const SizedBox(height: VbuTokens.space4),
          Text(
            'NAME',
            style: vbuMono(
              size: 11,
              weight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: VbuTokens.space2),
          VbuLabelledField(
            label: 'name',
            controller: _name,
            hint: 'human-readable name',
          ),
          const SizedBox(height: VbuTokens.space4),
          Text(
            'SYSTEM PROMPT',
            style: vbuMono(
              size: 11,
              weight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: VbuTokens.space2),
          TextField(
            controller: _systemPrompt,
            minLines: 8,
            maxLines: 40,
            style: vbuMono(size: 12, color: c.textPrimary),
            decoration: InputDecoration(
              hintText: 'the prompt the LLM sees on every turn for this agent',
              hintStyle: vbuMono(size: 11, color: c.textTertiary),
              filled: true,
              fillColor: c.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                borderSide: BorderSide(color: c.borderSubtle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section descriptor — one row of agent → knowledge-category linkage.
class _AgentConnectionSection {
  const _AgentConnectionSection({
    required this.label,
    required this.ids,
    required this.manifestPath,
  });
  final String label;
  final List<String> ids;
  final String manifestPath;
}

extension on _AgentDetailPaneState {
  Widget _connectionsBlock({
    required String title,
    required String subtitle,
    required List<_AgentConnectionSection> sections,
  }) {
    final c = VbuTokens.colorOf(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      padding: const EdgeInsets.all(VbuTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: vbuMono(
              size: 11,
              weight: FontWeight.w600,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: vbuMono(size: 10, color: c.textTertiary)),
          const SizedBox(height: VbuTokens.space3),
          for (final s in sections) ...<Widget>[
            _connectionRow(s),
            const SizedBox(height: VbuTokens.space2),
          ],
        ],
      ),
    );
  }

  Widget _connectionRow(_AgentConnectionSection s) {
    final c = VbuTokens.colorOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 90,
          child: Text(
            s.label,
            style: vbuMono(
              size: 11,
              weight: FontWeight.w500,
              color: c.textSecondary,
            ),
          ),
        ),
        Expanded(
          child:
              s.ids.isEmpty
                  ? Text(
                    '(none)',
                    style: vbuMono(size: 11, color: c.textTertiary),
                  )
                  : Wrap(
                    spacing: VbuTokens.space1,
                    runSpacing: VbuTokens.space1,
                    children: <Widget>[
                      for (final id in s.ids)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(
                              VbuTokens.radiusFull,
                            ),
                            border: Border.all(color: c.borderSubtle),
                          ),
                          child: Text(
                            id,
                            style: vbuMono(size: 10, color: c.mintDim),
                          ),
                        ),
                    ],
                  ),
        ),
      ],
    );
  }
}

Widget _readOnlyRow(String label, String value) {
  final c = VbuTokens.color;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(label, style: vbuMono(size: 11, color: c.textTertiary)),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: vbuMono(
              size: 11,
              color: value.isEmpty ? c.textTertiary : c.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );
}
