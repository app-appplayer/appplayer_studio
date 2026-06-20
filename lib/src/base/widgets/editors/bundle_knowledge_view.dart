/// Knowledge editor for a bundle's `manifest.json`. Panel + detail
/// layout — left column shows 5 surface headers stacked (SOURCES /
/// SKILLS / PROFILES / PHILOSOPHIES / AGENTS) with their entries; click
/// any row to view / edit its detail in the right pane.
///
/// Each surface maps to a manifest field:
///   * SOURCES        → `knowledge.sources[]` (each with `documents[]`
///                      nested; docs render as indented rows under the
///                      source they belong to).
///   * SKILLS         → `knowledge.skills[]`
///   * PROFILES       → `knowledge.profiles[]`
///   * PHILOSOPHIES   → `knowledge.philosophies[]`
///   * AGENTS         → `agents.agents[]` (top-level, separate from
///                      the knowledge map per spec).
///
/// Detail editors offer inline text fields for the small, high-traffic
/// fields (name / description / statement / systemPrompt) — they
/// autosave to manifest.json. The canonical authoring path is the
/// chat: `studio.builder.addKnowledgeSource / addKnowledgeDoc /
/// addSkill / addProfile / addPhilosophy / addAgent`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:appplayer_studio/ui.dart';

/// Knowledge surfaces — 9 panel sections.
///
///   * [source] — RAG input corpus (a distinct kind, separate from the 8 categories).
///   * 8 first-class categories: [fact] · [skill] · [profile] · [philosophy] ·
///     [workflow] · [pipeline] · [runbook] · [agent]. Each maps 1:1 to a
///     port / facade in `mcp_knowledge`; workflow/pipeline/runbook stay
///     separate (not merged into a single "ops" — schema, triggers, and
///     outputs all differ).
enum KnowledgeKind {
  source,
  fact,
  skill,
  profile,
  philosophy,
  workflow,
  pipeline,
  runbook,
  agent,
}

class KnowledgeSelection {
  const KnowledgeSelection(this.kind, this.idx, {this.docIdx = -1});
  final KnowledgeKind kind;
  final int idx;

  /// Only meaningful when [kind] == [KnowledgeKind.source]. When >= 0,
  /// the selection points to a nested `documents[docIdx]` under
  /// `sources[idx]`.
  final int docIdx;
}

class BundleKnowledgeView extends StatefulWidget {
  const BundleKnowledgeView({
    super.key,
    required this.bundlePath,
    this.reloadCounter = 0,
  });

  final String bundlePath;
  final int reloadCounter;

  @override
  State<BundleKnowledgeView> createState() => _BundleKnowledgeViewState();
}

class _BundleKnowledgeViewState extends State<BundleKnowledgeView> {
  List<Map<String, dynamic>> _sources = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _facts = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _skills = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _profiles = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _philosophies = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _workflows = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _pipelines = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _runbooks = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _agents = const <Map<String, dynamic>>[];
  KnowledgeSelection _sel = const KnowledgeSelection(KnowledgeKind.source, -1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BundleKnowledgeView old) {
    super.didUpdateWidget(old);
    if (old.bundlePath != widget.bundlePath ||
        old.reloadCounter != widget.reloadCounter) {
      _load();
    }
  }

  void _load() {
    List<Map<String, dynamic>> sources = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> facts = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> skills = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> profiles = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> philosophies = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> workflows = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> pipelines = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> runbooks = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> agents = const <Map<String, dynamic>>[];
    try {
      final f = File(p.join(widget.bundlePath, 'manifest.json'));
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map<String, dynamic>) {
          final knowledge = raw['knowledge'];
          if (knowledge is Map<String, dynamic>) {
            sources = _asList(knowledge['sources']);
            facts = _asList(knowledge['facts']);
            skills = _asList(knowledge['skills']);
            profiles = _asList(knowledge['profiles']);
            philosophies = _asList(knowledge['philosophies']);
            workflows = _asList(knowledge['workflows']);
            pipelines = _asList(knowledge['pipelines']);
            runbooks = _asList(knowledge['runbooks']);
          }
          // Agents — tolerate both shapes: top-level `agents: [...]`
          // (validator-style) and wrapped `agents: { agents: [...] }`
          // (the shape every built-in seed uses).
          final agentBlock = raw['agents'];
          if (agentBlock is List) {
            agents = <Map<String, dynamic>>[
              for (final e in agentBlock)
                if (e is Map<String, dynamic>) e,
            ];
          } else if (agentBlock is Map<String, dynamic>) {
            agents = _asList(agentBlock['agents']);
          }
        }
      }
    } catch (_) {
      /* leave empty */
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _facts = facts;
      _skills = skills;
      _profiles = profiles;
      _philosophies = philosophies;
      _workflows = workflows;
      _pipelines = pipelines;
      _runbooks = runbooks;
      _agents = agents;
      _sel = _clamp(_sel);
    });
  }

  static List<Map<String, dynamic>> _asList(Object? raw) =>
      <Map<String, dynamic>>[
        if (raw is List)
          for (final e in raw)
            if (e is Map<String, dynamic>) e,
      ];

  KnowledgeSelection _clamp(KnowledgeSelection s) {
    int clampIdx(int i, int n) => (i < 0 || i >= n) ? -1 : i;
    switch (s.kind) {
      case KnowledgeKind.source:
        final i = clampIdx(s.idx, _sources.length);
        if (i < 0) return const KnowledgeSelection(KnowledgeKind.source, -1);
        final docs = _docsOf(_sources[i]);
        final di = s.docIdx < 0 ? -1 : clampIdx(s.docIdx, docs.length);
        return KnowledgeSelection(KnowledgeKind.source, i, docIdx: di);
      case KnowledgeKind.fact:
        return KnowledgeSelection(
          KnowledgeKind.fact,
          clampIdx(s.idx, _facts.length),
        );
      case KnowledgeKind.skill:
        return KnowledgeSelection(
          KnowledgeKind.skill,
          clampIdx(s.idx, _skills.length),
        );
      case KnowledgeKind.profile:
        return KnowledgeSelection(
          KnowledgeKind.profile,
          clampIdx(s.idx, _profiles.length),
        );
      case KnowledgeKind.philosophy:
        return KnowledgeSelection(
          KnowledgeKind.philosophy,
          clampIdx(s.idx, _philosophies.length),
        );
      case KnowledgeKind.workflow:
        return KnowledgeSelection(
          KnowledgeKind.workflow,
          clampIdx(s.idx, _workflows.length),
        );
      case KnowledgeKind.pipeline:
        return KnowledgeSelection(
          KnowledgeKind.pipeline,
          clampIdx(s.idx, _pipelines.length),
        );
      case KnowledgeKind.runbook:
        return KnowledgeSelection(
          KnowledgeKind.runbook,
          clampIdx(s.idx, _runbooks.length),
        );
      case KnowledgeKind.agent:
        return KnowledgeSelection(
          KnowledgeKind.agent,
          clampIdx(s.idx, _agents.length),
        );
    }
  }

  static List<Map<String, dynamic>> _docsOf(Map<String, dynamic> source) =>
      _asList(source['documents']);

  Future<void> _mutateManifest(
    void Function(Map<String, dynamic> manifest) mutate,
  ) async {
    // Route the UI editor's edit through `McpBundleMutator.mutate` —
    // the same transactional authoring path the chat / MCP mutators
    // use. Schema validation, in-process mutex, and optimistic
    // checksum apply uniformly so the UI and MCP channels share a
    // single source of truth.
    try {
      await mk.McpBundleMutator.mutate<bool>(
        widget.bundlePath,
        options: const mk.McpLoaderOptions.lenient(),
        fn: (current) async {
          final raw = current.toJson();
          mutate(raw);
          final updated = mk.McpBundleLoader.fromJson(
            raw,
            options: const mk.McpLoaderOptions.lenient(),
          );
          return mk.MutationOutcome<bool>(updated: updated, result: true);
        },
      );
    } catch (_) {
      /* best-effort — keep UI responsive on schema fault */
    }
    _load();
  }

  Map<String, dynamic> _ensureMap(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is Map<String, dynamic>) return existing;
    final m =
        (existing is Map)
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
    parent[key] = m;
    return m;
  }

  Future<void> _patchKnowledgeList(
    String listKey,
    int idx,
    Map<String, dynamic> patch,
  ) async {
    await _mutateManifest((m) {
      final list = _ensureMap(m, 'knowledge')[listKey];
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _patchAgent(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final list = _ensureMap(m, 'agents')['agents'];
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _patchSourceDoc(
    int srcIdx,
    int docIdx,
    Map<String, dynamic> patch,
  ) async {
    await _mutateManifest((m) {
      final sources = _ensureMap(m, 'knowledge')['sources'];
      if (sources is! List || srcIdx < 0 || srcIdx >= sources.length) return;
      final src = sources[srcIdx];
      if (src is! Map) return;
      final docs = src['documents'];
      if (docs is! List || docIdx < 0 || docIdx >= docs.length) return;
      final cur = docs[docIdx];
      if (cur is! Map) return;
      docs[docIdx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
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
            width: 320,
            child: Container(
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: c.borderSubtle)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _surfaceHeader('SOURCES', _sources.length),
                    if (_sources.isEmpty)
                      _emptyRowHint(
                        'No knowledge sources. Ask the chat to '
                        'addKnowledgeSource (then addKnowledgeDoc per doc).',
                      )
                    else
                      _sourcesListBody(),
                    _surfaceHeader('FACTS', _facts.length),
                    if (_facts.isEmpty)
                      _emptyRowHint(
                        'No fact-graph triples. Each entry is a '
                        'subject / predicate / object with optional '
                        'confidence — author via chat.',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.fact,
                        _facts,
                        label: (f) => _factLabel(f),
                        sub: (f) {
                          final conf = f['confidence'];
                          return conf is num
                              ? 'confidence: ${conf.toStringAsFixed(2)}'
                              : '';
                        },
                      ),
                    _surfaceHeader('SKILLS', _skills.length),
                    if (_skills.isEmpty)
                      _emptyRowHint(
                        'No skills declared. Ask the chat to addSkill '
                        'with name + description + inputSchema.',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.skill,
                        _skills,
                        label:
                            (s) =>
                                s['name']?.toString() ??
                                s['id']?.toString() ??
                                '(skill)',
                        sub: (s) => s['description']?.toString() ?? '',
                      ),
                    _surfaceHeader('PROFILES', _profiles.length),
                    if (_profiles.isEmpty)
                      _emptyRowHint(
                        'No profiles declared. Ask the chat to addProfile '
                        '(tone / voice / audience).',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.profile,
                        _profiles,
                        label:
                            (s) =>
                                s['name']?.toString() ??
                                s['id']?.toString() ??
                                '(profile)',
                        sub: (s) => s['description']?.toString() ?? '',
                      ),
                    _surfaceHeader('PHILOSOPHIES', _philosophies.length),
                    if (_philosophies.isEmpty)
                      _emptyRowHint(
                        'No philosophies declared. Ask the chat to '
                        'addPhilosophy (statement + rationale).',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.philosophy,
                        _philosophies,
                        label: (s) => s['id']?.toString() ?? '(philosophy)',
                        sub: (s) => s['statement']?.toString() ?? '',
                      ),
                    _surfaceHeader('WORKFLOWS', _workflows.length),
                    if (_workflows.isEmpty)
                      _emptyRowHint(
                        'No workflows declared. Each entry is a stepped '
                        'sequence (`WorkflowPort`). manifest.knowledge.'
                        'workflows[] — author via chat.',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.workflow,
                        _workflows,
                        label:
                            (s) =>
                                s['name']?.toString() ??
                                s['id']?.toString() ??
                                '(workflow)',
                        sub: (s) => s['description']?.toString() ?? '',
                      ),
                    _surfaceHeader('PIPELINES', _pipelines.length),
                    if (_pipelines.isEmpty)
                      _emptyRowHint(
                        'No pipelines declared. Each entry is a data-flow '
                        'graph (`PipelinePort`). manifest.knowledge.'
                        'pipelines[] — author via chat.',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.pipeline,
                        _pipelines,
                        label:
                            (s) =>
                                s['name']?.toString() ??
                                s['id']?.toString() ??
                                '(pipeline)',
                        sub: (s) => s['description']?.toString() ?? '',
                      ),
                    _surfaceHeader('RUNBOOKS', _runbooks.length),
                    if (_runbooks.isEmpty)
                      _emptyRowHint(
                        'No runbooks declared. Each entry is an ops '
                        'procedure (`RunbookPort`). manifest.knowledge.'
                        'runbooks[] — author via chat.',
                      )
                    else
                      _entryListBody(
                        KnowledgeKind.runbook,
                        _runbooks,
                        label:
                            (s) =>
                                s['name']?.toString() ??
                                s['id']?.toString() ??
                                '(runbook)',
                        sub: (s) => s['description']?.toString() ?? '',
                      ),
                    // Agents moved out of the knowledge surface into
                    // their own bundle-mode card (`BundleAgentsView`)
                    // — agents are the assembly point that COMPOSES
                    // skills / profiles / philosophy / sources, not a
                    // ninth peer knowledge category. See
                    // `feedback_knowledge_definition` for the
                    // conceptual grouping; the manifest schema treats
                    // them as a top-level section.
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: _buildDetail()),
        ],
      ),
    );
  }

  Widget _sourcesListBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _sources.length; i++) ...<Widget>[
          _navRow(
            label: _sources[i]['id']?.toString() ?? '(source)',
            sub: 'documents: ${_docsOf(_sources[i]).length}',
            selected:
                _sel.kind == KnowledgeKind.source &&
                _sel.idx == i &&
                _sel.docIdx < 0,
            onTap:
                () => setState(
                  () => _sel = KnowledgeSelection(KnowledgeKind.source, i),
                ),
            trailingPill: '${_docsOf(_sources[i]).length} docs',
          ),
          for (var j = 0; j < _docsOf(_sources[i]).length; j++)
            _indentedRow(
              label: _docsOf(_sources[i])[j]['id']?.toString() ?? '(doc)',
              sub:
                  _docsOf(_sources[i])[j]['content']
                      ?.toString()
                      .replaceAll(RegExp(r'\s+'), ' ')
                      .trim() ??
                  '',
              selected:
                  _sel.kind == KnowledgeKind.source &&
                  _sel.idx == i &&
                  _sel.docIdx == j,
              onTap:
                  () => setState(
                    () =>
                        _sel = KnowledgeSelection(
                          KnowledgeKind.source,
                          i,
                          docIdx: j,
                        ),
                  ),
            ),
        ],
      ],
    );
  }

  Widget _entryListBody(
    KnowledgeKind kind,
    List<Map<String, dynamic>> list, {
    required String Function(Map<String, dynamic>) label,
    required String Function(Map<String, dynamic>) sub,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < list.length; i++)
          _navRow(
            label: label(list[i]),
            sub: sub(list[i]),
            selected: _sel.kind == kind && _sel.idx == i,
            onTap: () => setState(() => _sel = KnowledgeSelection(kind, i)),
          ),
      ],
    );
  }

  static String _factLabel(Map<String, dynamic> f) {
    final s = f['subject']?.toString() ?? '?';
    final p = f['predicate']?.toString() ?? '?';
    final o = f['object']?.toString() ?? '?';
    return '$s · $p · $o';
  }

  Widget _buildDetail() {
    final allEmpty =
        _sources.isEmpty &&
        _facts.isEmpty &&
        _skills.isEmpty &&
        _profiles.isEmpty &&
        _philosophies.isEmpty &&
        _workflows.isEmpty &&
        _pipelines.isEmpty &&
        _runbooks.isEmpty &&
        _agents.isEmpty;
    if (allEmpty || _sel.idx < 0) return _emptyDetail();
    switch (_sel.kind) {
      case KnowledgeKind.source:
        if (_sel.idx >= _sources.length) return _emptyDetail();
        final source = _sources[_sel.idx];
        if (_sel.docIdx < 0) {
          return _SourceDetail(
            key: ValueKey('source-${_sel.idx}'),
            source: source,
          );
        }
        final docs = _docsOf(source);
        if (_sel.docIdx >= docs.length) return _emptyDetail();
        return _DocDetail(
          key: ValueKey('source-${_sel.idx}-doc-${_sel.docIdx}'),
          doc: docs[_sel.docIdx],
          onUpdate: (patch) => _patchSourceDoc(_sel.idx, _sel.docIdx, patch),
        );
      case KnowledgeKind.fact:
        if (_sel.idx >= _facts.length) return _emptyDetail();
        return _FactDetail(
          key: ValueKey('fact-${_sel.idx}'),
          entry: _facts[_sel.idx],
          onUpdate: (patch) => _patchKnowledgeList('facts', _sel.idx, patch),
        );
      case KnowledgeKind.skill:
        if (_sel.idx >= _skills.length) return _emptyDetail();
        return _NameDescDetail(
          key: ValueKey('skill-${_sel.idx}'),
          entry: _skills[_sel.idx],
          kindLabel: 'Skill',
          subtitle: 'manifest.knowledge.skills[]',
          onUpdate: (patch) => _patchKnowledgeList('skills', _sel.idx, patch),
        );
      case KnowledgeKind.profile:
        if (_sel.idx >= _profiles.length) return _emptyDetail();
        return _NameDescDetail(
          key: ValueKey('profile-${_sel.idx}'),
          entry: _profiles[_sel.idx],
          kindLabel: 'Profile',
          subtitle: 'manifest.knowledge.profiles[]',
          onUpdate: (patch) => _patchKnowledgeList('profiles', _sel.idx, patch),
        );
      case KnowledgeKind.philosophy:
        if (_sel.idx >= _philosophies.length) return _emptyDetail();
        return _PhilosophyDetail(
          key: ValueKey('philosophy-${_sel.idx}'),
          entry: _philosophies[_sel.idx],
          onUpdate:
              (patch) => _patchKnowledgeList('philosophies', _sel.idx, patch),
        );
      case KnowledgeKind.workflow:
        if (_sel.idx >= _workflows.length) return _emptyDetail();
        return _NameDescDetail(
          key: ValueKey('workflow-${_sel.idx}'),
          entry: _workflows[_sel.idx],
          kindLabel: 'Workflow',
          subtitle: 'manifest.knowledge.workflows[]',
          onUpdate:
              (patch) => _patchKnowledgeList('workflows', _sel.idx, patch),
        );
      case KnowledgeKind.pipeline:
        if (_sel.idx >= _pipelines.length) return _emptyDetail();
        return _NameDescDetail(
          key: ValueKey('pipeline-${_sel.idx}'),
          entry: _pipelines[_sel.idx],
          kindLabel: 'Pipeline',
          subtitle: 'manifest.knowledge.pipelines[]',
          onUpdate:
              (patch) => _patchKnowledgeList('pipelines', _sel.idx, patch),
        );
      case KnowledgeKind.runbook:
        if (_sel.idx >= _runbooks.length) return _emptyDetail();
        return _NameDescDetail(
          key: ValueKey('runbook-${_sel.idx}'),
          entry: _runbooks[_sel.idx],
          kindLabel: 'Runbook',
          subtitle: 'manifest.knowledge.runbooks[]',
          onUpdate: (patch) => _patchKnowledgeList('runbooks', _sel.idx, patch),
        );
      case KnowledgeKind.agent:
        if (_sel.idx >= _agents.length) return _emptyDetail();
        return _AgentDetail(
          key: ValueKey('agent-${_sel.idx}'),
          entry: _agents[_sel.idx],
          onUpdate: (patch) => _patchAgent(_sel.idx, patch),
        );
    }
  }

  Widget _emptyDetail() {
    final c = VbuTokens.colorOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VbuTokens.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.menu_book_outlined, size: 28, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space2),
            Text(
              'Pick a row on the left.',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 13,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: VbuTokens.space2),
            Text(
              '9 surfaces — Sources (RAG input · BM25 corpus, separate '
              'from the 8 categories) and 8 first-class categories: '
              'Facts (S/P/O graph), Skills, Profiles, Philosophies, '
              'Workflows (WorkflowPort), Pipelines (PipelinePort), '
              'Runbooks (RunbookPort), Agents. Author by chatting — '
              'studio.builder.addKnowledge* + addSkill + addProfile + '
              'addPhilosophy + addAgent handle the writes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Left-panel chrome ----

  Widget _surfaceHeader(String title, int count) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '$title ($count)',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: c.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyRowHint(String text) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 10,
          color: c.textTertiary,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _navRow({
    required String label,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
    String? trailingPill,
  }) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VbuTokens.space3,
          vertical: 6,
        ),
        color: selected ? c.surface3 : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: selected ? c.textPrimary : c.textSecondary,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 10,
                        color: c.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
            if (trailingPill != null && trailingPill.isNotEmpty) ...<Widget>[
              const SizedBox(width: VbuTokens.space1),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Text(
                  trailingPill,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 9,
                    color: c.mintDim,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _indentedRow({
    required String label,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(
          left: VbuTokens.space5,
          right: VbuTokens.space3,
          top: 4,
          bottom: 4,
        ),
        color: selected ? c.surface3 : Colors.transparent,
        child: Row(
          children: <Widget>[
            Text('·', style: TextStyle(color: c.textTertiary, fontSize: 12)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                sub.isEmpty ? label : '$label  ·  $sub',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: selected ? c.textPrimary : c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared detail-pane chrome
// ---------------------------------------------------------------------------

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.subtitle,
    this.kindPill,
  });
  final String title;
  final String subtitle;
  final String? kindPill;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space5,
        vertical: VbuTokens.space3,
      ),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontSans,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: vbuMono(size: 10, color: c.textTertiary)),
              ],
            ),
          ),
          if (kindPill != null && kindPill!.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                border: Border.all(color: c.borderSubtle),
              ),
              child: Text(
                kindPill!,
                style: vbuMono(size: 10, color: c.mintDim),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.body});
  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: VbuTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: VbuTokens.space2),
            child: Text(
              title,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: c.textTertiary,
              ),
            ),
          ),
          body,
        ],
      ),
    );
  }
}

Widget _multilineBox(
  BuildContext context,
  TextEditingController c,
  String hint, {
  int minLines = 3,
  int maxLines = 10,
}) {
  final col = VbuTokens.colorOf(context);
  return Container(
    decoration: BoxDecoration(
      color: col.surface,
      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
      border: Border.all(color: col.borderSubtle),
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: VbuTokens.space3,
      vertical: VbuTokens.space2,
    ),
    child: TextField(
      controller: c,
      minLines: minLines,
      maxLines: maxLines,
      style: vbuMono(size: 12, color: col.textPrimary),
      decoration: InputDecoration(
        border: InputBorder.none,
        isDense: true,
        hintText: hint,
      ),
    ),
  );
}

Widget _readOnlyRow(String label, String value) {
  final c = VbuTokens.color;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 92,
          child: Text(label, style: vbuMono(size: 11, color: c.textSecondary)),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '(empty)' : value,
            style: vbuMono(
              size: 12,
              color: value.isEmpty ? c.textTertiary : c.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Per-category detail widgets
// ---------------------------------------------------------------------------

class _SourceDetail extends StatelessWidget {
  const _SourceDetail({super.key, required this.source});
  final Map<String, dynamic> source;

  @override
  Widget build(BuildContext context) {
    final id = source['id']?.toString() ?? '';
    final docs = _BundleKnowledgeViewState._docsOf(source);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: 'Knowledge source',
            subtitle: 'manifest.knowledge.sources[]',
            kindPill: '${docs.length} docs',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _readOnlyRow('id', id),
                _DetailSection(
                  title: 'DOCUMENTS',
                  body:
                      docs.isEmpty
                          ? Text(
                            'No documents yet. Ask the chat to '
                            'addKnowledgeDoc per document.',
                            style: vbuMono(
                              size: 11,
                              color: VbuTokens.colorOf(context).textTertiary,
                            ),
                          )
                          : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              for (final d in docs)
                                _readOnlyRow(
                                  d['id']?.toString() ?? '(doc)',
                                  (d['content']?.toString() ?? '')
                                      .replaceAll(RegExp(r'\s+'), ' ')
                                      .trim(),
                                ),
                            ],
                          ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DocDetail extends StatefulWidget {
  const _DocDetail({super.key, required this.doc, required this.onUpdate});
  final Map<String, dynamic> doc;
  final void Function(Map<String, dynamic>) onUpdate;
  @override
  State<_DocDetail> createState() => _DocDetailState();
}

class _DocDetailState extends State<_DocDetail> {
  late TextEditingController _content;
  Timer? _save;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(
      text: widget.doc['content']?.toString() ?? '',
    )..addListener(() {
      _save?.cancel();
      _save = Timer(
        const Duration(milliseconds: 300),
        () => widget.onUpdate(<String, dynamic>{'content': _content.text}),
      );
    });
  }

  @override
  void dispose() {
    _save?.cancel();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.doc['id']?.toString() ?? '';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: 'Knowledge doc',
            subtitle: 'manifest.knowledge.sources[].documents[]',
            kindPill: 'id: $id',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _readOnlyRow('id', id),
                _DetailSection(
                  title: 'CONTENT',
                  body: _multilineBox(
                    context,
                    _content,
                    'doc body — markdown / plain prose',
                    minLines: 6,
                    maxLines: 30,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FactDetail extends StatefulWidget {
  const _FactDetail({super.key, required this.entry, required this.onUpdate});
  final Map<String, dynamic> entry;
  final void Function(Map<String, dynamic>) onUpdate;
  @override
  State<_FactDetail> createState() => _FactDetailState();
}

class _FactDetailState extends State<_FactDetail> {
  late TextEditingController _subject;
  late TextEditingController _predicate;
  late TextEditingController _object;
  late TextEditingController _confidence;
  Timer? _save;

  @override
  void initState() {
    super.initState();
    _subject = TextEditingController(
      text: widget.entry['subject']?.toString() ?? '',
    )..addListener(_schedule);
    _predicate = TextEditingController(
      text: widget.entry['predicate']?.toString() ?? '',
    )..addListener(_schedule);
    _object = TextEditingController(
      text: widget.entry['object']?.toString() ?? '',
    )..addListener(_schedule);
    final conf = widget.entry['confidence'];
    _confidence = TextEditingController(
      text: conf is num ? conf.toString() : '',
    )..addListener(_schedule);
  }

  void _schedule() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 300), () {
      final patch = <String, dynamic>{
        'subject': _subject.text,
        'predicate': _predicate.text,
        'object': _object.text,
      };
      final txt = _confidence.text.trim();
      if (txt.isEmpty) {
        patch['confidence'] = null;
      } else {
        final parsed = double.tryParse(txt);
        if (parsed != null && parsed >= 0 && parsed <= 1) {
          patch['confidence'] = parsed;
        }
      }
      widget.onUpdate(patch);
    });
  }

  @override
  void dispose() {
    _save?.cancel();
    _subject.dispose();
    _predicate.dispose();
    _object.dispose();
    _confidence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final triple = '${_subject.text} · ${_predicate.text} · ${_object.text}';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: 'Fact triple',
            subtitle: 'manifest.knowledge.facts[]',
            kindPill: triple.length <= 56 ? triple : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _DetailSection(
                  title: 'SUBJECT',
                  body: VbuLabelledField(
                    label: 'subject',
                    controller: _subject,
                    hint: 'the entity (id or name)',
                  ),
                ),
                _DetailSection(
                  title: 'PREDICATE',
                  body: VbuLabelledField(
                    label: 'predicate',
                    controller: _predicate,
                    hint: 'the relation verb',
                  ),
                ),
                _DetailSection(
                  title: 'OBJECT',
                  body: VbuLabelledField(
                    label: 'object',
                    controller: _object,
                    hint: 'target entity or literal',
                  ),
                ),
                _DetailSection(
                  title: 'CONFIDENCE',
                  body: VbuLabelledField(
                    label: 'confidence',
                    controller: _confidence,
                    hint: '0.0 – 1.0 (optional)',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NameDescDetail extends StatefulWidget {
  const _NameDescDetail({
    super.key,
    required this.entry,
    required this.kindLabel,
    required this.subtitle,
    required this.onUpdate,
  });
  final Map<String, dynamic> entry;
  final String kindLabel;
  final String subtitle;
  final void Function(Map<String, dynamic>) onUpdate;
  @override
  State<_NameDescDetail> createState() => _NameDescDetailState();
}

class _NameDescDetailState extends State<_NameDescDetail> {
  late TextEditingController _name;
  late TextEditingController _description;
  Timer? _save;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.entry['name']?.toString() ?? '')
      ..addListener(_schedule);
    _description = TextEditingController(
      text: widget.entry['description']?.toString() ?? '',
    )..addListener(_schedule);
  }

  void _schedule() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 300), () {
      widget.onUpdate(<String, dynamic>{
        'name': _name.text,
        'description': _description.text,
      });
    });
  }

  @override
  void dispose() {
    _save?.cancel();
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.entry['id']?.toString() ?? '';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: widget.kindLabel,
            subtitle: widget.subtitle,
            kindPill: id.isEmpty ? null : 'id: $id',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _readOnlyRow('id', id),
                _DetailSection(
                  title: 'NAME',
                  body: VbuLabelledField(
                    label: 'name',
                    controller: _name,
                    hint: 'short display name',
                  ),
                ),
                _DetailSection(
                  title: 'DESCRIPTION',
                  body: _multilineBox(
                    context,
                    _description,
                    'what this is + when to use it',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhilosophyDetail extends StatefulWidget {
  const _PhilosophyDetail({
    super.key,
    required this.entry,
    required this.onUpdate,
  });
  final Map<String, dynamic> entry;
  final void Function(Map<String, dynamic>) onUpdate;
  @override
  State<_PhilosophyDetail> createState() => _PhilosophyDetailState();
}

class _PhilosophyDetailState extends State<_PhilosophyDetail> {
  late TextEditingController _statement;
  late TextEditingController _rationale;
  Timer? _save;

  @override
  void initState() {
    super.initState();
    _statement = TextEditingController(
      text: widget.entry['statement']?.toString() ?? '',
    )..addListener(_schedule);
    _rationale = TextEditingController(
      text: widget.entry['rationale']?.toString() ?? '',
    )..addListener(_schedule);
  }

  void _schedule() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 300), () {
      widget.onUpdate(<String, dynamic>{
        'statement': _statement.text,
        'rationale': _rationale.text,
      });
    });
  }

  @override
  void dispose() {
    _save?.cancel();
    _statement.dispose();
    _rationale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.entry['id']?.toString() ?? '';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: 'Philosophy',
            subtitle: 'manifest.knowledge.philosophies[]',
            kindPill: id.isEmpty ? null : 'id: $id',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _readOnlyRow('id', id),
                _DetailSection(
                  title: 'STATEMENT',
                  body: _multilineBox(
                    context,
                    _statement,
                    'the principle — one or two sentences',
                  ),
                ),
                _DetailSection(
                  title: 'RATIONALE',
                  body: _multilineBox(
                    context,
                    _rationale,
                    'why this principle — context, examples',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentDetail extends StatefulWidget {
  const _AgentDetail({super.key, required this.entry, required this.onUpdate});
  final Map<String, dynamic> entry;
  final void Function(Map<String, dynamic>) onUpdate;
  @override
  State<_AgentDetail> createState() => _AgentDetailState();
}

class _AgentDetailState extends State<_AgentDetail> {
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
    final id = widget.entry['id']?.toString() ?? '';
    final role = widget.entry['role']?.toString() ?? '';
    final model = widget.entry['model'];
    String modelLabel = '';
    if (model is Map) {
      final prov = model['provider']?.toString() ?? '';
      final mname = model['model']?.toString() ?? '';
      modelLabel = (prov.isEmpty && mname.isEmpty) ? '' : '$prov · $mname';
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _DetailHeader(
            title: 'Agent',
            subtitle: 'manifest.agents.agents[]',
            kindPill: role.isEmpty ? null : 'role: $role',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VbuTokens.space5,
              vertical: VbuTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _readOnlyRow('id', id),
                _readOnlyRow('role', role),
                _readOnlyRow('model', modelLabel),
                _DetailSection(
                  title: 'NAME',
                  body: VbuLabelledField(
                    label: 'name',
                    controller: _name,
                    hint: 'human-readable name',
                  ),
                ),
                _DetailSection(
                  title: 'SYSTEM PROMPT',
                  body: _multilineBox(
                    context,
                    _systemPrompt,
                    'the prompt the LLM sees on every turn for this agent',
                    minLines: 8,
                    maxLines: 40,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
