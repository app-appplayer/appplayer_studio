/// Unified Tools mode — single workspace surface for the 4 builder
/// targets a Studio Builder author wires together: tool defs, domain
/// icon row, "/" composer chips, and settings sections/fields.
///
/// Top tab row switches between the 4 surfaces; each surface renders a
/// split layout (left list, right detail editor). All edits autosave
/// to the bundle's `manifest.json`; settings field values additionally
/// autosave to a per-package overrides file (shared with the legacy
/// gear-icon dialog) so they survive reloads.
///
/// File-scoped private classes (`_ToolDetail`, `_DomainActionEditor`,
/// `_SlashCommandEditor`, `_SettingsSectionEditor`,
/// `_SettingsFieldEditor`, plus shared chrome `_ToolsDetailHeader`,
/// `_ToolsDetailSection`, `_ToolsChatHint`) implement the per-row
/// detail bodies. `_SettingsSectionsPreview` + `_ManifestFieldList` are
/// kept private here until the next refactor phase generalises them
/// into a single base widget shared with the chrome Settings dialog.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:appplayer_studio/ui.dart';

/// Surface kind for the unified Tools mode left navigator. The Tools
/// mode is a single builder surface that covers 4 things: the tool
/// definitions themselves + the 3 places they get wired to (always-on
/// domain icons, chat slash composer chips, settings sections/fields).
enum BundleToolsKind { tool, domain, slash, section, lifecycle }

/// Outer layout shape for [BundleToolsView]. The interior (left list +
/// right detail editors, data loading, autosave) is identical across
/// shapes — only the surface picker differs.
///
///   * [tabs] — top tab bar (Tools · Domain Icons · / Commands ·
///     Settings) switches the visible list. Original idiom.
///   * [panel] — single left column shows all 4 section headers stacked
///     with their rows underneath. Click any row to flip the right
///     detail; no kind tab needed.
enum BundleToolsLayout { tabs, panel }

/// Selection in the Tools mode left navigator. [idx] indexes into the
/// surface's list. [fieldIdx] is only used for `BundleToolsKind.section` —
/// `-1` means the section itself is selected (overview / label edit /
/// section-level + field), `≥0` means a specific field within that
/// section is selected.
class BundleToolsSelection {
  const BundleToolsSelection(this.kind, this.idx, {this.fieldIdx = -1});
  final BundleToolsKind kind;
  final int idx;
  final int fieldIdx;
}

/// Unified Tools mode — single workspace surface for the 4 builder
/// targets a Studio Builder author wires together: tool defs, domain
/// icon row, "/" composer chips, and settings sections/fields. Left
/// pane is a grouped navigator (4 surface headers with `+` add buttons
/// + per-row entries); right pane is an inline editor whose shape
/// switches on the selected row's surface kind. All edits autosave to
/// the bundle's `manifest.json`; settings field values additionally
/// autosave to a per-package overrides file (shared with the legacy
/// gear-icon dialog) so they survive reloads.
class BundleToolsView extends StatefulWidget {
  const BundleToolsView({
    super.key,
    required this.bundlePath,
    required this.overridesFile,
    required this.chromeBridge,
    required this.reloadCounter,
    this.layout = BundleToolsLayout.tabs,
    this.visibleKinds,
  });
  final String bundlePath;
  final String overridesFile;
  final ChromeBridge chromeBridge;

  /// Tab's reloadCounter — bumped by `_reloadTab` after a manifest
  /// mutation. didUpdateWidget watches this so the left-pane list
  /// re-reads disk whenever a builder tool fires `reload_tab`.
  final int reloadCounter;

  /// Outer surface picker shape — see [BundleToolsLayout].
  final BundleToolsLayout layout;

  /// Subset of [BundleToolsKind] surfaces this view should expose.
  /// Null = show every kind (default). Callers that know the
  /// authoring scope (e.g. an AppPlayer App project doesn't carry
  /// domain icons / lifecycle / slash commands) pass a restricted
  /// set so the tab bar only renders the kinds that apply.
  final Set<BundleToolsKind>? visibleKinds;
  @override
  State<BundleToolsView> createState() => _BundleToolsViewState();
}

class _BundleToolsViewState extends State<BundleToolsView> {
  List<Map<String, dynamic>> _tools = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _domain = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _slash = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _sections = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _lifecycle = const <Map<String, dynamic>>[];
  Map<String, dynamic>? _ui;
  BundleToolsSelection _sel = const BundleToolsSelection(
    BundleToolsKind.tool,
    -1,
  );

  @override
  void initState() {
    super.initState();
    _load();
    // Universal renderer activator may flip the sub-tab via
    // `chromeBridge.toolsSubTab`. Adopt the current value on mount + on
    // every change. The view's own user-driven tab clicks (`_tabBtn`)
    // also write to the notifier so MCP `current` queries match what
    // the user sees.
    widget.chromeBridge.toolsSubTab.addListener(_adoptSubTabFromBridge);
    _adoptSubTabFromBridge();
  }

  @override
  void didUpdateWidget(covariant BundleToolsView old) {
    super.didUpdateWidget(old);
    if (old.bundlePath != widget.bundlePath ||
        old.reloadCounter != widget.reloadCounter) {
      _load();
    }
    if (!identical(old.chromeBridge, widget.chromeBridge)) {
      old.chromeBridge.toolsSubTab.removeListener(_adoptSubTabFromBridge);
      widget.chromeBridge.toolsSubTab.addListener(_adoptSubTabFromBridge);
      _adoptSubTabFromBridge();
    }
  }

  @override
  void dispose() {
    widget.chromeBridge.toolsSubTab.removeListener(_adoptSubTabFromBridge);
    super.dispose();
  }

  void _adoptSubTabFromBridge() {
    final raw = widget.chromeBridge.toolsSubTab.value;
    BundleToolsKind? kind;
    switch (raw) {
      case 'tool':
        kind = BundleToolsKind.tool;
        break;
      case 'domain':
        kind = BundleToolsKind.domain;
        break;
      case 'slash':
        kind = BundleToolsKind.slash;
        break;
      case 'section':
        kind = BundleToolsKind.section;
        break;
      case 'lifecycle':
        kind = BundleToolsKind.lifecycle;
        break;
    }
    if (kind == null || kind == _sel.kind) return;
    // Ignore a bridge-driven flip onto a kind we've been told to
    // hide. The user can still navigate the visible kinds via the
    // local tab bar; MCP callers that target a hidden kind get a
    // no-op rather than surface a tab the host has masked off.
    final visible = widget.visibleKinds;
    if (visible != null && !visible.contains(kind)) return;
    setState(() => _sel = BundleToolsSelection(kind!, -1));
  }

  /// Resolve the kind to display in the tab bar — never returns a
  /// kind absent from [BundleToolsView.visibleKinds]. Falls back to
  /// the first allowed kind so the body always has something to
  /// render even when the current selection is filtered out.
  BundleToolsKind _effectiveKind() {
    final visible = widget.visibleKinds;
    if (visible == null || visible.contains(_sel.kind)) return _sel.kind;
    for (final k in BundleToolsKind.values) {
      if (visible.contains(k)) return k;
    }
    return _sel.kind;
  }

  void _load() {
    List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> domain = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> slash = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> sections = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> lifecycle = const <Map<String, dynamic>>[];
    Map<String, dynamic>? ui;
    try {
      final f = File(p.join(widget.bundlePath, 'manifest.json'));
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is Map<String, dynamic>) {
          // Tools — tolerate either `tools: { tools: [...] }` (nested,
          // current spec) or `tools: [...]` (flat, older drafts).
          final ts = raw['tools'];
          final list =
              (ts is Map<String, dynamic>
                      ? ts['tools']
                      : (ts is List ? ts : null))
                  as List?;
          tools = <Map<String, dynamic>>[
            for (final t in (list ?? const []))
              if (t is Map<String, dynamic>) t,
          ];
          // Domain icon entries + lifecycle slots.
          final wiring = raw['wiring'];
          if (wiring is Map<String, dynamic>) {
            final da = wiring['domainActions'];
            if (da is List) {
              domain = <Map<String, dynamic>>[
                for (final e in da)
                  if (e is Map<String, dynamic>) e,
              ];
            }
            final lc = wiring['lifecycle'];
            if (lc is List) {
              lifecycle = <Map<String, dynamic>>[
                for (final e in lc)
                  if (e is Map<String, dynamic>) e,
              ];
            }
          }
          // Slash commands.
          final chat = raw['chat'];
          if (chat is Map<String, dynamic>) {
            final cmds = chat['slashCommands'];
            if (cmds is List) {
              slash = <Map<String, dynamic>>[
                for (final c in cmds)
                  if (c is Map<String, dynamic>) c,
              ];
            }
          }
          // Settings sections — prefer top-level `settings.sections` (the
          // canonical S10-7 shape); fall back to a nested `manifest.settings`
          // for the older draft layout where everything sat under an outer
          // `manifest` wrapper.
          Map<String, dynamic>? settings;
          final settingsTop = raw['settings'];
          if (settingsTop is Map<String, dynamic>) {
            settings = settingsTop;
          } else {
            final mWrap = raw['manifest'];
            if (mWrap is Map<String, dynamic>) {
              final nested = mWrap['settings'];
              if (nested is Map<String, dynamic>) settings = nested;
            }
          }
          if (settings != null) {
            final secs = settings['sections'];
            if (secs is List) {
              sections = <Map<String, dynamic>>[
                for (final s in secs)
                  if (s is Map<String, dynamic>) s,
              ];
            }
          }
          // ui/app.json — for cross-reference scan (UI WIRING section
          // on the tool detail).
          final uiSection = raw['ui'];
          if (uiSection is Map<String, dynamic>) {
            final uiPath = uiSection['path']?.toString();
            if (uiPath != null && uiPath.isNotEmpty) {
              final uiFile = File(p.join(widget.bundlePath, uiPath));
              if (uiFile.existsSync()) {
                final uiRaw = jsonDecode(uiFile.readAsStringSync());
                if (uiRaw is Map<String, dynamic>) ui = uiRaw;
              }
            }
          }
        }
      }
    } catch (_) {
      // Swallow — empty state covers the "couldn't parse" case.
    }
    if (!mounted) return;
    setState(() {
      _tools = tools;
      _domain = domain;
      _slash = slash;
      _sections = sections;
      _lifecycle = lifecycle;
      _ui = ui;
      _sel = _clampSelection(_sel);
    });
  }

  /// Re-clamp the selection after a manifest reload — keeps the
  /// previously selected row visible when an entry near the end gets
  /// added/removed, and falls back to "nothing selected" (`idx = -1`)
  /// when its surface goes empty.
  BundleToolsSelection _clampSelection(BundleToolsSelection s) {
    int clamp(int v, int max) {
      if (max <= 0) return -1;
      if (v < 0) return -1;
      if (v >= max) return max - 1;
      return v;
    }

    switch (s.kind) {
      case BundleToolsKind.tool:
        return BundleToolsSelection(
          BundleToolsKind.tool,
          clamp(s.idx, _tools.length),
        );
      case BundleToolsKind.domain:
        return BundleToolsSelection(
          BundleToolsKind.domain,
          clamp(s.idx, _domain.length),
        );
      case BundleToolsKind.slash:
        return BundleToolsSelection(
          BundleToolsKind.slash,
          clamp(s.idx, _slash.length),
        );
      case BundleToolsKind.section:
        final ci = clamp(s.idx, _sections.length);
        if (ci < 0) {
          return const BundleToolsSelection(BundleToolsKind.section, -1);
        }
        final fieldCount = _fieldsOf(_sections[ci]).length;
        final fi = s.fieldIdx < 0 ? -1 : clamp(s.fieldIdx, fieldCount);
        return BundleToolsSelection(BundleToolsKind.section, ci, fieldIdx: fi);
      case BundleToolsKind.lifecycle:
        return BundleToolsSelection(
          BundleToolsKind.lifecycle,
          clamp(s.idx, _lifecycle.length),
        );
    }
  }

  static String _kindToString(BundleToolsKind k) {
    switch (k) {
      case BundleToolsKind.tool:
        return 'tool';
      case BundleToolsKind.domain:
        return 'domain';
      case BundleToolsKind.slash:
        return 'slash';
      case BundleToolsKind.section:
        return 'section';
      case BundleToolsKind.lifecycle:
        return 'lifecycle';
    }
  }

  static List<Map<String, dynamic>> _fieldsOf(Map<String, dynamic> section) {
    final fs = section['fields'];
    if (fs is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final f in fs)
        if (f is Map<String, dynamic>) f,
    ];
  }

  /// Atomic manifest.json read → mutate → write → reload. Mirrors the
  /// host class's `_runKnowledgeMutation` path so on-disk shape stays
  /// identical regardless of whether the edit came from the MCP tool
  /// (chat-driven) or from the inline editor (UI-driven).
  Future<void> _mutateManifest(
    void Function(Map<String, dynamic> manifest) mutate,
  ) async {
    final f = File(p.join(widget.bundlePath, 'manifest.json'));
    if (!await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return;
      mutate(raw);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
    } catch (_) {
      /* best effort — reload below picks up partial state */
    }
    _load();
  }

  Map<String, dynamic> _ensureMapAt(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is Map<String, dynamic>) return existing;
    if (existing is Map) {
      final m = Map<String, dynamic>.from(existing);
      parent[key] = m;
      return m;
    }
    final m = <String, dynamic>{};
    parent[key] = m;
    return m;
  }

  List<dynamic> _ensureListAt(Map<String, dynamic> parent, String key) {
    final existing = parent[key];
    if (existing is List) return existing;
    final list = <dynamic>[];
    parent[key] = list;
    return list;
  }

  // ---- Surface mutators (tools) ----

  Future<void> _addTool() async {
    String name = 'new_tool';
    int i = 1;
    while (_tools.any((t) => t['name'] == name)) {
      i++;
      name = 'new_tool_$i';
    }
    final entry = <String, dynamic>{
      'name': name,
      'kind': 'host',
      'description': '',
      'inputSchema': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    };
    await _mutateManifest((m) {
      final ts = m['tools'];
      final list =
          (ts is Map<String, dynamic>)
              ? _ensureListAt(ts, 'tools')
              : _ensureListAt(_ensureMapAt(m, 'tools'), 'tools');
      list.add(entry);
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(BundleToolsKind.tool, _tools.length - 1),
    );
  }

  Future<void> _updateTool(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final ts = m['tools'];
      final list = (ts is Map<String, dynamic>) ? ts['tools'] : ts;
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _deleteTool(int idx) async {
    await _mutateManifest((m) {
      final ts = m['tools'];
      final list = (ts is Map<String, dynamic>) ? ts['tools'] : ts;
      if (list is! List || idx < 0 || idx >= list.length) return;
      list.removeAt(idx);
    });
    if (!mounted) return;
    setState(() => _sel = const BundleToolsSelection(BundleToolsKind.tool, -1));
  }

  // ---- Surface mutators (domain icons) ----

  Future<void> _addDomainAction(String toolName) async {
    await _mutateManifest((m) {
      final list = _ensureListAt(_ensureMapAt(m, 'wiring'), 'domainActions');
      list.add(<String, dynamic>{
        'tool': toolName,
        'icon': 'extension',
        'tooltip': toolName,
      });
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(
            BundleToolsKind.domain,
            _domain.length - 1,
          ),
    );
  }

  Future<void> _updateDomainAction(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final list =
          (m['wiring'] is Map) ? (m['wiring'] as Map)['domainActions'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _deleteDomainAction(int idx) async {
    await _mutateManifest((m) {
      final list =
          (m['wiring'] is Map) ? (m['wiring'] as Map)['domainActions'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      list.removeAt(idx);
    });
    if (!mounted) return;
    setState(
      () => _sel = const BundleToolsSelection(BundleToolsKind.domain, -1),
    );
  }

  // ---- Surface mutators (lifecycle slots) ----

  Future<void> _updateLifecycle(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final list =
          (m['wiring'] is Map) ? (m['wiring'] as Map)['lifecycle'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _deleteLifecycle(int idx) async {
    await _mutateManifest((m) {
      final list =
          (m['wiring'] is Map) ? (m['wiring'] as Map)['lifecycle'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      list.removeAt(idx);
    });
    if (!mounted) return;
    setState(
      () => _sel = const BundleToolsSelection(BundleToolsKind.lifecycle, -1),
    );
  }

  // ---- Surface mutators (slash commands) ----

  Future<void> _addSlash() async {
    String cmd = '/new';
    int i = 1;
    while (_slash.any((s) => s['command'] == cmd)) {
      i++;
      cmd = '/new$i';
    }
    await _mutateManifest((m) {
      final list = _ensureListAt(_ensureMapAt(m, 'chat'), 'slashCommands');
      list.add(<String, dynamic>{'command': cmd, 'description': ''});
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(BundleToolsKind.slash, _slash.length - 1),
    );
  }

  Future<void> _updateSlash(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final list =
          (m['chat'] is Map) ? (m['chat'] as Map)['slashCommands'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _deleteSlash(int idx) async {
    await _mutateManifest((m) {
      final list =
          (m['chat'] is Map) ? (m['chat'] as Map)['slashCommands'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      list.removeAt(idx);
    });
    if (!mounted) return;
    setState(
      () => _sel = const BundleToolsSelection(BundleToolsKind.slash, -1),
    );
  }

  // ---- Surface mutators (settings sections + fields) ----

  Future<void> _addSection() async {
    String key = 'section';
    int i = 1;
    while (_sections.any((s) => s['key'] == key)) {
      i++;
      key = 'section_$i';
    }
    await _mutateManifest((m) {
      final list = _ensureListAt(_ensureMapAt(m, 'settings'), 'sections');
      list.add(<String, dynamic>{
        'key': key,
        'label': key,
        'fields': <Map<String, dynamic>>[],
      });
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(
            BundleToolsKind.section,
            _sections.length - 1,
          ),
    );
  }

  Future<void> _updateSection(int idx, Map<String, dynamic> patch) async {
    await _mutateManifest((m) {
      final list =
          (m['settings'] is Map) ? (m['settings'] as Map)['sections'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      final cur = list[idx];
      if (cur is! Map) return;
      list[idx] = Map<String, dynamic>.from(cur)..addAll(patch);
    });
  }

  Future<void> _deleteSection(int idx) async {
    await _mutateManifest((m) {
      final list =
          (m['settings'] is Map) ? (m['settings'] as Map)['sections'] : null;
      if (list is! List || idx < 0 || idx >= list.length) return;
      list.removeAt(idx);
    });
    if (!mounted) return;
    setState(
      () => _sel = const BundleToolsSelection(BundleToolsKind.section, -1),
    );
  }

  Future<void> _addField(int sectionIdx) async {
    if (sectionIdx < 0 || sectionIdx >= _sections.length) return;
    final existing = _fieldsOf(_sections[sectionIdx]);
    String key = 'field';
    int i = 1;
    while (existing.any((f) => f['key'] == key)) {
      i++;
      key = 'field_$i';
    }
    await _mutateManifest((m) {
      final list =
          (m['settings'] is Map) ? (m['settings'] as Map)['sections'] : null;
      if (list is! List || sectionIdx < 0 || sectionIdx >= list.length) return;
      final section = list[sectionIdx];
      if (section is! Map) return;
      final updated = Map<String, dynamic>.from(section);
      final fields =
          (updated['fields'] is List)
              ? List<dynamic>.from(updated['fields'] as List)
              : <dynamic>[];
      fields.add(<String, dynamic>{
        'key': key,
        'label': key,
        'type': 'text',
        'value': '',
      });
      updated['fields'] = fields;
      list[sectionIdx] = updated;
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(
            BundleToolsKind.section,
            sectionIdx,
            fieldIdx: _fieldsOf(_sections[sectionIdx]).length - 1,
          ),
    );
  }

  Future<void> _updateField(
    int sectionIdx,
    int fieldIdx,
    Map<String, dynamic> patch,
  ) async {
    await _mutateManifest((m) {
      final list =
          (m['settings'] is Map) ? (m['settings'] as Map)['sections'] : null;
      if (list is! List || sectionIdx < 0 || sectionIdx >= list.length) return;
      final section = list[sectionIdx];
      if (section is! Map) return;
      final fields = section['fields'];
      if (fields is! List || fieldIdx < 0 || fieldIdx >= fields.length) return;
      final cur = fields[fieldIdx];
      if (cur is! Map) return;
      final updated = Map<String, dynamic>.from(section);
      final newFields = List<dynamic>.from(fields);
      newFields[fieldIdx] = Map<String, dynamic>.from(cur)..addAll(patch);
      updated['fields'] = newFields;
      list[sectionIdx] = updated;
    });
  }

  Future<void> _deleteField(int sectionIdx, int fieldIdx) async {
    await _mutateManifest((m) {
      final list =
          (m['settings'] is Map) ? (m['settings'] as Map)['sections'] : null;
      if (list is! List || sectionIdx < 0 || sectionIdx >= list.length) return;
      final section = list[sectionIdx];
      if (section is! Map) return;
      final fields = section['fields'];
      if (fields is! List || fieldIdx < 0 || fieldIdx >= fields.length) return;
      final updated = Map<String, dynamic>.from(section);
      final newFields = List<dynamic>.from(fields)..removeAt(fieldIdx);
      updated['fields'] = newFields;
      list[sectionIdx] = updated;
    });
    if (!mounted) return;
    setState(
      () =>
          _sel = BundleToolsSelection(
            BundleToolsKind.section,
            sectionIdx,
            fieldIdx: -1,
          ),
    );
  }

  // ---- Cross-reference scans (for tool detail) ----

  /// Collect every wiring entry that targets [shortName] across the
  /// two wiring surfaces — manifest.wiring.domainActions[] and
  /// manifest.chat.slashCommands[] (only entries that declare a `tool`
  /// field). Settings sections are wired via field-level `value`, not
  /// `tool`, so they don't appear here.
  List<Map<String, String>> _wiringRefs(String shortName) {
    final hits = <Map<String, String>>[];
    for (final entry in _domain) {
      if (entry['tool']?.toString() != shortName) continue;
      hits.add(<String, String>{
        'kind': 'domain',
        'surface': 'domain icon',
        'label': entry['tooltip']?.toString() ?? shortName,
        'sub': 'icon: ${entry['icon']?.toString() ?? 'extension'}',
        'icon': entry['icon']?.toString() ?? 'extension',
      });
    }
    for (final entry in _slash) {
      if (entry['tool']?.toString() != shortName) continue;
      final cmd = entry['command']?.toString() ?? '';
      hits.add(<String, String>{
        'kind': 'slash',
        'surface': 'slash command',
        'label': cmd,
        'sub': entry['description']?.toString() ?? '',
        'icon': 'slash',
      });
    }
    return hits;
  }

  /// Walk [node] (and any nested map / list children) collecting every
  /// `{type:'tool', tool: <name>}` action where the tool name matches
  /// either [shortName] (bare) or `<bundleNs>.<shortName>` (the
  /// activated form). Returns a list of `{path, host}` rows where
  /// `path` is a dot-separated location and `host` is the parent widget
  /// shape (`button`, `ToolForm`, `lifecycle.onInit`, …) — enough
  /// context for the user to find the call site in ui/app.json.
  List<Map<String, String>> _scanRefs(String shortName) {
    final ui = _ui;
    if (ui == null) return const <Map<String, String>>[];
    final hits = <Map<String, String>>[];
    void walk(Object? node, String path, String hostHint) {
      if (node is Map) {
        final type = node['type']?.toString();
        // Treat any nested `click` / `onTap` / `onSelect` / `onChanged`
        // / `lifecycle.onInit` map as a potential action host. We don't
        // care which one — we just look for `{type:'tool', tool: ...}`
        // shapes anywhere in the subtree.
        if (type == 'tool') {
          final t = node['tool']?.toString() ?? '';
          if (t == shortName ||
              t.endsWith('.$shortName') ||
              t == shortName.split('.').last) {
            hits.add(<String, String>{
              'path': path.isEmpty ? '<root>' : path,
              'host': hostHint.isEmpty ? '(action)' : hostHint,
              'tool': t,
            });
          }
        }
        for (final entry in node.entries) {
          final k = entry.key.toString();
          // Update hostHint when we descend into a typed widget node.
          final nextHost =
              (type != null && k == 'click' ||
                      type != null && k == 'onTap' ||
                      type != null && k == 'onSelect' ||
                      type != null && k == 'onChanged')
                  ? '$type.$k'
                  : (k == 'lifecycle' ? 'lifecycle' : hostHint);
          final nextPath = path.isEmpty ? k : '$path.$k';
          walk(entry.value, nextPath, nextHost);
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$path[$i]', hostHint);
        }
      }
    }

    walk(ui, '', '');
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child:
          widget.layout == BundleToolsLayout.panel
              ? _panelLayout()
              : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Top tab row — 4 surfaces (Tools / Domain Icons / /
                  // Commands / Settings). Clicking a tab switches the body
                  // to that surface's list (+ selected detail). `+` add
                  // buttons are dropped per the bibe ("vibe") mode —
                  // chat-driven LLM tool calls do the authoring.
                  _tabBar(_effectiveKind()),
                  Expanded(child: _bodyForKind(_effectiveKind())),
                ],
              ),
    );
  }

  /// Panel-mode outer: single left column with all 4 surface headers +
  /// rows stacked (scrollable as one), right pane shows the selected
  /// row's detail editor. Same data / autosave / detail editors as the
  /// tabbed mode — only the picker shape differs.
  Widget _panelLayout() {
    final c = VbuTokens.colorOf(context);
    return Row(
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
                  _surfaceHeader('TOOLS', _tools.length),
                  if (_tools.isEmpty)
                    _emptyRowHint(
                      'No tools yet. Ask the chat to design + register one.',
                    )
                  else
                    _toolsListBody(),
                  _surfaceHeader('DOMAIN ICONS', _domain.length),
                  if (_domain.isEmpty)
                    _emptyRowHint(
                      'No domain icons wired. Ask the chat to wire a tool '
                      'to the chrome ProjectHeader row.',
                    )
                  else
                    _domainListBody(),
                  _surfaceHeader('/ COMMANDS', _slash.length),
                  if (_slash.isEmpty)
                    _emptyRowHint(
                      'No / commands yet. Ask the chat to add a slash chip '
                      '(template or direct-dispatch).',
                    )
                  else
                    _slashListBody(),
                  _surfaceHeader('SETTINGS', _sections.length),
                  if (_sections.isEmpty)
                    _emptyRowHint(
                      'No settings sections yet. Ask the chat to add a '
                      'section with its fields.',
                    )
                  else
                    _settingsListBody(),
                  _surfaceHeader('LIFECYCLE', _lifecycle.length),
                  if (_lifecycle.isEmpty)
                    _emptyRowHint(
                      'No lifecycle wiring yet. Slots like project.new / '
                      'project.save / edit.undo route the chrome system '
                      'buttons to a tool — ask the chat to wire one.',
                    )
                  else
                    _lifecycleListBody(),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: _buildDetail()),
      ],
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

  /// Top tab bar — one tab per Tools-mode surface kind. Active tab
  /// gets a mint underline + filled background; non-active tabs are
  /// monochrome. Each tab shows its surface's row count as a pill so
  /// the author sees at a glance "how many domain icons / slash
  /// commands / settings sections does this mbd carry".
  Widget _tabBar(BundleToolsKind active) {
    final c = VbuTokens.colorOf(context);
    final allTabs = <(BundleToolsKind, String, int, IconData)>[
      (BundleToolsKind.tool, 'Tools', _tools.length, Icons.build_outlined),
      (BundleToolsKind.section, 'Settings', _sections.length, Icons.tune),
      (
        BundleToolsKind.domain,
        'Domain Icons',
        _domain.length,
        Icons.dashboard_customize_outlined,
      ),
      (
        BundleToolsKind.slash,
        '/ Commands',
        _slash.length,
        Icons.alternate_email,
      ),
      (
        BundleToolsKind.lifecycle,
        'Lifecycle',
        _lifecycle.length,
        Icons.history,
      ),
    ];
    final visible = widget.visibleKinds;
    final tabs =
        visible == null
            ? allTabs
            : allTabs.where((t) => visible.contains(t.$1)).toList();
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.tools.tab_bar',
        'id': 'tools-tabs',
        'label': _kindToString(active),
      },
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: c.surface2,
          border: Border(bottom: BorderSide(color: c.borderSubtle)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final entry in tabs)
              _tabBtn(
                entry.$1,
                entry.$2,
                entry.$3,
                entry.$4,
                active == entry.$1,
              ),
          ],
        ),
      ),
    );
  }

  Widget _tabBtn(
    BundleToolsKind kind,
    String label,
    int count,
    IconData icon,
    bool active,
  ) {
    final c = VbuTokens.colorOf(context);
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.tools.tab',
        'id': _kindToString(kind),
        'label': label,
        'active': active.toString(),
      },
      child: InkWell(
        onTap: () {
          // Publish to the chromeBridge notifier first so the listener
          // path (`_adoptSubTabFromBridge`) runs; that handler skips its
          // own setState when the kind matches, so we still need to
          // setState locally for the visual change. The notifier write
          // keeps MCP `current` queries in sync with user clicks.
          widget.chromeBridge.toolsSubTab.value = _kindToString(kind);
          setState(() => _sel = BundleToolsSelection(kind, -1));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: VbuTokens.space4,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: active ? c.surface3 : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: active ? c.mint : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 14, color: active ? c.mint : c.textTertiary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: active ? c.textPrimary : c.textSecondary,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 9,
                    color: c.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Per-tab body — currently each tab renders a split layout: a list
  /// of the tab's rows on the left, a detail editor for the selected
  /// row on the right. The list is read-only chrome (no `+`/edit
  /// affordances — LLM-driven authoring instead); the detail editor's
  /// inline form fields remain as a manual fallback for power users.
  Widget _bodyForKind(BundleToolsKind kind) {
    switch (kind) {
      case BundleToolsKind.tool:
        return _splitBody(
          listBuilder: _toolsListBody,
          rowCount: _tools.length,
          emptyHint: 'No tools yet. Ask the chat to design + register one.',
        );
      case BundleToolsKind.domain:
        return _splitBody(
          listBuilder: _domainListBody,
          rowCount: _domain.length,
          emptyHint:
              'No domain icons wired. Ask the chat to wire a tool to '
              'the chrome ProjectHeader row.',
        );
      case BundleToolsKind.slash:
        return _splitBody(
          listBuilder: _slashListBody,
          rowCount: _slash.length,
          emptyHint:
              'No / commands yet. Ask the chat to add a slash chip '
              '(template or direct-dispatch).',
        );
      case BundleToolsKind.section:
        return _splitBody(
          listBuilder: _settingsListBody,
          rowCount: _sections.length,
          emptyHint:
              'No settings sections yet. Ask the chat to add a section '
              'with its fields.',
        );
      case BundleToolsKind.lifecycle:
        return _splitBody(
          listBuilder: _lifecycleListBody,
          rowCount: _lifecycle.length,
          emptyHint:
              'No lifecycle wiring yet. Slots like project.new / project.save '
              '/ edit.undo route the chrome system buttons to a tool — ask '
              'the chat to wire one.',
        );
    }
  }

  Widget _splitBody({
    required Widget Function() listBuilder,
    required int rowCount,
    required String emptyHint,
  }) {
    final c = VbuTokens.colorOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 320,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: c.borderSubtle)),
            ),
            child:
                rowCount == 0
                    ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(VbuTokens.space5),
                        child: Text(
                          emptyHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: VbuTokens.fontMono,
                            fontSize: 11,
                            color: c.textTertiary,
                            height: 1.5,
                          ),
                        ),
                      ),
                    )
                    : SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: listBuilder(),
                    ),
          ),
        ),
        Expanded(child: _buildDetail()),
      ],
    );
  }

  Widget _toolsListBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _tools.length; i++)
          _navRow(
            label: _tools[i]['name']?.toString() ?? '(unnamed)',
            sub: _toolSubLabel(_tools[i]),
            icon: Icons.build_outlined,
            selected: _sel.kind == BundleToolsKind.tool && _sel.idx == i,
            onTap:
                () => setState(
                  () => _sel = BundleToolsSelection(BundleToolsKind.tool, i),
                ),
            trailingPill: _tools[i]['kind']?.toString() ?? 'host',
          ),
      ],
    );
  }

  Widget _domainListBody() {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _domain.length; i++)
          _navRow(
            label:
                _domain[i]['tooltip']?.toString() ??
                _domain[i]['tool']?.toString() ??
                '(unnamed)',
            sub: '→ ${_domain[i]['tool']?.toString() ?? '?'}',
            icon: _iconFor(_domain[i]['icon']?.toString() ?? 'extension'),
            selected: _sel.kind == BundleToolsKind.domain && _sel.idx == i,
            onTap:
                () => setState(
                  () => _sel = BundleToolsSelection(BundleToolsKind.domain, i),
                ),
            trailingPill: _toolKindPill(_domain[i]['tool']?.toString() ?? ''),
            iconTint: c.mint,
          ),
      ],
    );
  }

  Widget _slashListBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _slash.length; i++)
          _navRow(
            label: _slash[i]['command']?.toString() ?? '/?',
            sub:
                (_slash[i]['tool']?.toString().isNotEmpty ?? false)
                    ? '→ ${_slash[i]['tool']}'
                    : (_slash[i]['template']?.toString() ?? '(template)'),
            icon: Icons.alternate_email,
            selected: _sel.kind == BundleToolsKind.slash && _sel.idx == i,
            onTap:
                () => setState(
                  () => _sel = BundleToolsSelection(BundleToolsKind.slash, i),
                ),
            trailingPill:
                (_slash[i]['tool']?.toString().isNotEmpty ?? false)
                    ? _toolKindPill(_slash[i]['tool']?.toString() ?? '')
                    : 'template',
          ),
      ],
    );
  }

  Widget _lifecycleListBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _lifecycle.length; i++)
          _navRow(
            label: _lifecycle[i]['slot']?.toString() ?? '(slot)',
            sub: '→ ${_lifecycle[i]['tool']?.toString() ?? '?'}',
            icon: Icons.history,
            selected: _sel.kind == BundleToolsKind.lifecycle && _sel.idx == i,
            onTap:
                () => setState(
                  () =>
                      _sel = BundleToolsSelection(BundleToolsKind.lifecycle, i),
                ),
            trailingPill: _toolKindPill(
              _lifecycle[i]['tool']?.toString() ?? '',
            ),
          ),
      ],
    );
  }

  Widget _settingsListBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < _sections.length; i++) ...<Widget>[
          _navRow(
            label:
                _sections[i]['label']?.toString() ??
                _sections[i]['key']?.toString() ??
                '(section)',
            sub: 'key: ${_sections[i]['key']?.toString() ?? '?'}',
            icon: Icons.tune,
            selected:
                _sel.kind == BundleToolsKind.section &&
                _sel.idx == i &&
                _sel.fieldIdx < 0,
            onTap:
                () => setState(
                  () =>
                      _sel = BundleToolsSelection(
                        BundleToolsKind.section,
                        i,
                        fieldIdx: -1,
                      ),
                ),
            trailingPill: '${_fieldsOf(_sections[i]).length} fields',
          ),
          for (var j = 0; j < _fieldsOf(_sections[i]).length; j++)
            _navRowIndented(
              label:
                  _fieldsOf(_sections[i])[j]['label']?.toString() ??
                  _fieldsOf(_sections[i])[j]['key']?.toString() ??
                  '?',
              sub:
                  'type: ${_fieldsOf(_sections[i])[j]['type']?.toString() ?? '?'}',
              selected:
                  _sel.kind == BundleToolsKind.section &&
                  _sel.idx == i &&
                  _sel.fieldIdx == j,
              onTap:
                  () => setState(
                    () =>
                        _sel = BundleToolsSelection(
                          BundleToolsKind.section,
                          i,
                          fieldIdx: j,
                        ),
                  ),
            ),
        ],
      ],
    );
  }

  // ---- Helpers (left pane chrome + tool picker) ----

  Widget _surfaceHeader(String title, int count, {VoidCallback? onAdd}) {
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
          if (onAdd != null)
            InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.add, size: 14, color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _navRow({
    required String label,
    required String sub,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    String? trailingPill,
    Color? iconTint,
  }) {
    final c = VbuTokens.colorOf(context);
    // Panel layout drops the per-row icon box — the section header is
    // already the visual anchor for each surface, so per-row icons just
    // add noise. Tabbed layout keeps the icon (no header above rows).
    final showIcon = widget.layout != BundleToolsLayout.panel;
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.tools.nav_row',
        'id': '${_kindToString(_sel.kind)}/$label',
        'label': label,
        'active': selected.toString(),
      },
      child: InkWell(
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
              if (showIcon) ...<Widget>[
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                    border: Border.all(color: c.borderSubtle),
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: iconTint ?? (selected ? c.mint : c.textSecondary),
                  ),
                ),
                const SizedBox(width: VbuTokens.space2),
              ],
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
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
      ),
    );
  }

  Widget _navRowIndented({
    required String label,
    required String sub,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final c = VbuTokens.colorOf(context);
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.tools.nav_row_indented',
        'id': 'field/$label',
        'label': label,
        'active': selected.toString(),
      },
      child: InkWell(
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
                  '$label  ·  $sub',
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
      ),
    );
  }

  /// Sub-label for a TOOLS row — picks the most useful "where does
  /// this come from" hint based on the tool's `kind`/`target` shape.
  /// host → "in-process"; mcp → server endpoint (URL or stdio command);
  /// cloud → endpoint; js → entry file. Falls back to the raw `kind`.
  static String _toolSubLabel(Map<String, dynamic> tool) {
    final kind = tool['kind']?.toString() ?? 'host';
    final target = tool['target'];
    if (kind == 'host') return 'in-process · builtin';
    if (kind == 'mcp' && target is Map) {
      final url = target['url']?.toString();
      if (url != null && url.isNotEmpty) return 'mcp · $url';
      final cmd = target['command']?.toString();
      if (cmd != null && cmd.isNotEmpty) return 'mcp · stdio $cmd';
      return 'mcp · (no endpoint)';
    }
    if (kind == 'cloud' && target is Map) {
      final url = target['url']?.toString();
      if (url != null && url.isNotEmpty) return 'cloud · $url';
      return 'cloud · (no endpoint)';
    }
    if (kind == 'js' && target is Map) {
      final entry = target['entry']?.toString();
      if (entry != null && entry.isNotEmpty) return 'js · $entry';
    }
    return kind;
  }

  /// Look up a tool by its bare name within this view's `_tools` list.
  /// Returns null when the wired tool isn't declared in the manifest
  /// (e.g. the row references a tool from another mbd, or the name
  /// drifted out of sync).
  Map<String, dynamic>? _toolByName(String name) {
    if (name.isEmpty) return null;
    for (final t in _tools) {
      if (t['name']?.toString() == name) return t;
    }
    return null;
  }

  /// Trailing pill for a wiring row — shows the wired tool's `kind`
  /// (host/mcp/cloud/js). When the tool isn't in this mbd's manifest,
  /// show `?` so the user sees the broken wire.
  String _toolKindPill(String toolName) {
    final t = _toolByName(toolName);
    if (t == null) return toolName.isEmpty ? '?' : 'extern';
    return t['kind']?.toString() ?? 'host';
  }

  /// Compact icon-name → IconData map for the left-pane domain rows.
  /// Mirrors the host's `_materialIconByName` (kept private there) so
  /// unknown names fall back to `extension`.
  static IconData _iconFor(String name) {
    const m = <String, IconData>{
      'extension': Icons.extension_outlined,
      'play': Icons.play_arrow_outlined,
      'stop': Icons.stop_outlined,
      'refresh': Icons.refresh,
      'add': Icons.add,
      'delete': Icons.delete_outlined,
      'edit': Icons.edit_outlined,
      'save': Icons.save_outlined,
      'search': Icons.search,
      'filter': Icons.filter_alt_outlined,
      'history': Icons.history,
      'star': Icons.star_outline,
      'flag': Icons.flag_outlined,
      'bug': Icons.bug_report_outlined,
      'check': Icons.check,
      'sync': Icons.sync,
      'cloud': Icons.cloud_outlined,
      'database': Icons.storage_outlined,
      'terminal': Icons.terminal,
      'graph': Icons.account_tree_outlined,
      'chart': Icons.bar_chart_outlined,
      'table': Icons.table_rows_outlined,
      'mail': Icons.mail_outlined,
      'send': Icons.send_outlined,
      'lock': Icons.lock_outline,
      'unlock': Icons.lock_open_outlined,
      'key': Icons.key_outlined,
      'shield': Icons.shield_outlined,
      'palette': Icons.palette_outlined,
      'image': Icons.image_outlined,
      'audio': Icons.music_note_outlined,
      'video': Icons.video_library_outlined,
      'file': Icons.insert_drive_file_outlined,
      'folder': Icons.folder_outlined,
      'link': Icons.link,
      'share': Icons.share_outlined,
      'export': Icons.file_upload,
      'import': Icons.file_download,
      'tune': Icons.tune,
    };
    return m[name] ?? Icons.extension_outlined;
  }

  Future<void> _pickToolAndAddDomain() async {
    if (_tools.isEmpty) return;
    final c = VbuTokens.colorOf(context);
    final name = await showMenu<String>(
      context: context,
      color: c.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: const RelativeRect.fromLTRB(200, 120, 800, 0),
      items: <PopupMenuEntry<String>>[
        for (final t in _tools)
          PopupMenuItem<String>(
            value: t['name']?.toString() ?? '',
            height: 30,
            child: Text(
              t['name']?.toString() ?? '?',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (name == null || name.isEmpty) return;
    await _addDomainAction(name);
  }

  // ---- Detail switcher ----

  Widget _buildDetail() {
    final allEmpty =
        _tools.isEmpty &&
        _domain.isEmpty &&
        _slash.isEmpty &&
        _sections.isEmpty &&
        _lifecycle.isEmpty;
    if (allEmpty || _sel.idx < 0) return _emptyDetail();
    switch (_sel.kind) {
      case BundleToolsKind.tool:
        if (_sel.idx >= _tools.length) return _emptyDetail();
        final t = _tools[_sel.idx];
        final name = t['name']?.toString() ?? '';
        return _ToolDetail(
          key: ValueKey('tool-${_sel.idx}-$name'),
          tool: t,
          refs: _scanRefs(name),
          wiringRefs: _wiringRefs(name),
          onUpdate: (patch) => _updateTool(_sel.idx, patch),
          onDelete: () => _deleteTool(_sel.idx),
        );
      case BundleToolsKind.domain:
        if (_sel.idx >= _domain.length) return _emptyDetail();
        return _DomainActionEditor(
          key: ValueKey('domain-${_sel.idx}'),
          entry: _domain[_sel.idx],
          allTools: _tools,
          onUpdate: (patch) => _updateDomainAction(_sel.idx, patch),
          onDelete: () => _deleteDomainAction(_sel.idx),
        );
      case BundleToolsKind.slash:
        if (_sel.idx >= _slash.length) return _emptyDetail();
        return _SlashCommandEditor(
          key: ValueKey('slash-${_sel.idx}'),
          entry: _slash[_sel.idx],
          allTools: _tools,
          onUpdate: (patch) => _updateSlash(_sel.idx, patch),
          onDelete: () => _deleteSlash(_sel.idx),
        );
      case BundleToolsKind.section:
        if (_sel.idx >= _sections.length) return _emptyDetail();
        final section = _sections[_sel.idx];
        if (_sel.fieldIdx < 0) {
          return _SettingsSectionEditor(
            key: ValueKey(
              'section-${_sel.idx}-${section['key']?.toString() ?? ''}',
            ),
            section: section,
            overridesFile: widget.overridesFile,
            onUpdate: (patch) => _updateSection(_sel.idx, patch),
            onDelete: () => _deleteSection(_sel.idx),
            onAddField: () => _addField(_sel.idx),
          );
        }
        final fields = _fieldsOf(section);
        if (_sel.fieldIdx >= fields.length) return _emptyDetail();
        return _SettingsFieldEditor(
          key: ValueKey('field-${_sel.idx}-${_sel.fieldIdx}'),
          field: fields[_sel.fieldIdx],
          overridesFile: widget.overridesFile,
          onUpdate: (patch) => _updateField(_sel.idx, _sel.fieldIdx, patch),
          onDelete: () => _deleteField(_sel.idx, _sel.fieldIdx),
        );
      case BundleToolsKind.lifecycle:
        if (_sel.idx >= _lifecycle.length) return _emptyDetail();
        return _LifecycleEntryEditor(
          key: ValueKey('lifecycle-${_sel.idx}'),
          entry: _lifecycle[_sel.idx],
          allTools: _tools,
          onUpdate: (patch) => _updateLifecycle(_sel.idx, patch),
          onDelete: () => _deleteLifecycle(_sel.idx),
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
            Icon(Icons.build_outlined, size: 28, color: c.textTertiary),
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
              '4 builder surfaces — Tools (the verbs), Domain icons '
              '(persistent buttons), / commands (chat composer chips), '
              'Settings (inline sections + fields). Author by chatting '
              '— no manual add buttons needed.',
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
}

/// Right pane of [BundleToolsView] when a tool row is selected. Edits
/// the tool's name + description inline (autosave on every keystroke
/// via [onUpdate]); reads-only the structured bits (kind / target /
/// schemas) which are designed in chat. Shows where the tool gets
/// called from (UI wiring) and where it's surfaced (ADDITIONAL WIRING)
/// so the author can navigate to that wiring's row to edit it. Delete
/// button removes the tool from manifest.tools.tools[] entirely.
class _ToolDetail extends StatefulWidget {
  const _ToolDetail({
    super.key,
    required this.tool,
    required this.refs,
    required this.wiringRefs,
    required this.onUpdate,
    required this.onDelete,
  });

  final Map<String, dynamic> tool;
  final List<Map<String, String>> refs;
  final List<Map<String, String>> wiringRefs;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;

  @override
  State<_ToolDetail> createState() => _ToolDetailState();
}

class _ToolDetailState extends State<_ToolDetail> {
  late TextEditingController _name;
  late TextEditingController _desc;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.tool['name']?.toString() ?? '')
      ..addListener(
        () => widget.onUpdate(<String, dynamic>{'name': _name.text}),
      );
    _desc = TextEditingController(
      text: widget.tool['description']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'description': _desc.text}),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  /// Material icon for the wiring kind shown in ADDITIONAL WIRING rows.
  /// `domain` = persistent icon button on the activity bar; `slash` =
  /// chat composer chip; `settings` = entry inside the gear-icon menu.
  IconData _kindIcon(String kind) {
    switch (kind) {
      case 'slash':
        return Icons.alternate_email;
      case 'settings':
        return Icons.tune;
      case 'domain':
      default:
        return Icons.dashboard_customize_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final tool = widget.tool;
    final refs = widget.refs;
    final wiringRefs = widget.wiringRefs;
    final kind = tool['kind']?.toString() ?? '?';
    final target = tool['target'];
    final entry = (target is Map ? target['entry']?.toString() : null) ?? '';
    final fn = (target is Map ? target['fn']?.toString() : null) ?? '';
    final input = tool['inputSchema'];
    final output = tool['outputSchema'];

    Widget section(String title, Widget body) {
      return Padding(
        padding: const EdgeInsets.only(bottom: VbuTokens.space4),
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

    Widget keyValueRow(String k, String v) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 72,
              child: Text(
                k,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: c.textTertiary,
                ),
              ),
            ),
            Expanded(
              child: Text(
                v,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget schemaBlock(Object? schema) {
      if (schema is! Map) {
        return Text(
          '(none)',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        );
      }
      final props = schema['properties'];
      if (props is! Map || props.isEmpty) {
        return Text(
          '{}',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        );
      }
      final required =
          (schema['required'] is List)
              ? (schema['required'] as List).map((e) => e.toString()).toSet()
              : <String>{};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in props.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 140,
                    child: Row(
                      children: <Widget>[
                        Text(
                          entry.key.toString(),
                          style: TextStyle(
                            fontFamily: VbuTokens.fontMono,
                            fontSize: 11,
                            color: c.textPrimary,
                          ),
                        ),
                        if (required.contains(entry.key)) ...<Widget>[
                          const SizedBox(width: 4),
                          Text(
                            '*',
                            style: TextStyle(
                              fontFamily: VbuTokens.fontMono,
                              fontSize: 11,
                              color: c.amber,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: Text(
                      (entry.value is Map
                              ? (entry.value as Map)['type']?.toString()
                              : null) ??
                          '?',
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 11,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Tool',
            subtitle: 'manifest.tools.tools[]',
            kindPill: 'kind: $kind',
            onDelete: widget.onDelete,
            deleteLabel: 'Delete tool',
          ),
          section(
            'NAME',
            VbuLabelledField(
              label: 'name',
              controller: _name,
              hint: 'tool_name',
            ),
          ),
          section(
            'DESCRIPTION',
            VbuLabelledField(
              label: 'description',
              controller: _desc,
              hint: 'what the tool does',
            ),
          ),
          section(
            'TARGET',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (entry.isNotEmpty) keyValueRow('entry', entry),
                if (fn.isNotEmpty) keyValueRow('fn', fn),
                if (entry.isEmpty && fn.isEmpty)
                  Text(
                    '(no target — non-js kind)',
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 11,
                      color: c.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
          section('INPUT SCHEMA', schemaBlock(input)),
          section('OUTPUT SCHEMA', schemaBlock(output)),
          section(
            'ADDITIONAL WIRING — ${wiringRefs.length} surface${wiringRefs.length == 1 ? '' : 's'}',
            wiringRefs.isEmpty
                ? Text(
                  'Not wired to a domain icon / slash command / settings '
                  'entry yet. Surface this tool by calling '
                  'studio.builder.addDomainAction (always-visible icon), '
                  'studio.builder.addSlashCommand (chat composer chip; '
                  'set the optional tool field for direct dispatch), or '
                  'studio.builder.addSettingsEntry (gear-menu entry) so '
                  'the user can trigger it without typing the tool name.',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    color: c.textTertiary,
                    height: 1.5,
                  ),
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final r in wiringRefs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: VbuTokens.space2,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: c.surface3,
                            borderRadius: BorderRadius.circular(
                              VbuTokens.radiusSm,
                            ),
                            border: Border.all(color: c.borderSubtle),
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                _kindIcon(r['kind'] ?? 'domain'),
                                size: 12,
                                color: c.mintDim,
                              ),
                              const SizedBox(width: VbuTokens.space2),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      r['label'] ?? r['surface'] ?? '',
                                      style: TextStyle(
                                        fontFamily: VbuTokens.fontMono,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                    if ((r['sub'] ?? '').isNotEmpty)
                                      Text(
                                        r['sub']!,
                                        style: TextStyle(
                                          fontFamily: VbuTokens.fontMono,
                                          fontSize: 10,
                                          color: c.textTertiary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: c.surface2,
                                  borderRadius: BorderRadius.circular(
                                    VbuTokens.radiusFull,
                                  ),
                                  border: Border.all(color: c.borderSubtle),
                                ),
                                child: Text(
                                  r['surface'] ?? '',
                                  style: TextStyle(
                                    fontFamily: VbuTokens.fontMono,
                                    fontSize: 9,
                                    color: c.mintDim,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
          ),
          section(
            'UI WIRING — ${refs.length} reference${refs.length == 1 ? '' : 's'}',
            refs.isEmpty
                ? Text(
                  'Not called from any UI widget. Ask the chat to wire '
                  'this tool into ui/app.json (e.g. add a button whose '
                  'click action calls "${_name.text}"), or call '
                  'studio.builder.writeUI directly.',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    color: c.textTertiary,
                    height: 1.5,
                  ),
                )
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final r in refs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: VbuTokens.space2,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: c.surface3,
                            borderRadius: BorderRadius.circular(
                              VbuTokens.radiusSm,
                            ),
                            border: Border.all(color: c.borderSubtle),
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.link, size: 12, color: c.mintDim),
                              const SizedBox(width: VbuTokens.space2),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      r['host'] ?? '',
                                      style: TextStyle(
                                        fontFamily: VbuTokens.fontMono,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                    Text(
                                      r['path'] ?? '',
                                      style: TextStyle(
                                        fontFamily: VbuTokens.fontMono,
                                        fontSize: 10,
                                        color: c.textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                r['tool'] ?? '',
                                style: TextStyle(
                                  fontFamily: VbuTokens.fontMono,
                                  fontSize: 10,
                                  color: c.mintDim,
                                ),
                              ),
                            ],
                          ),
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

/// Header for every Tools-mode detail pane — title + subtitle (the
/// manifest path the surface writes to) + kind pill + delete button.
/// Consistent across the 5 detail widgets (_ToolDetail +
/// _DomainActionEditor + _SlashCommandEditor + _SettingsSectionEditor
/// + _SettingsFieldEditor) so the user always knows where the data
/// lives on disk and how to remove it.
class _ToolsDetailHeader extends StatelessWidget {
  const _ToolsDetailHeader({
    required this.title,
    required this.subtitle,
    this.kindPill,
    required this.onDelete,
    required this.deleteLabel,
  });
  final String title;
  final String subtitle;
  final String? kindPill;
  final VoidCallback onDelete;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.tools.detail_header',
        'id': 'detail/$title',
        'label': title,
        'title': subtitle,
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: VbuTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: VbuTokens.fontMono,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontFamily: VbuTokens.fontMono,
                          fontSize: 10,
                          color: c.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (kindPill != null) ...<Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VbuTokens.space2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                      border: Border.all(color: c.borderDefault),
                    ),
                    child: Text(
                      kindPill!,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 10,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: VbuTokens.space2),
                ],
                IconButton(
                  tooltip: deleteLabel,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: c.textTertiary,
                  ),
                  onPressed: onDelete,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mono-caps section header used by every detail editor. Pulled out so
/// the 5 detail widgets share the exact same visual rhythm with the
/// surface headers in the left navigator.
class _ToolsDetailSection extends StatelessWidget {
  const _ToolsDetailSection({required this.title, required this.body});
  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: VbuTokens.space4),
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

/// "Ask the chat" advisory block — every detail editor renders one of
/// these to remind the user that **the canonical way to change wiring
/// is to say it in the chat**, not fiddle with form fields. Form
/// fields are kept as a fallback for users who already know the exact
/// edit they want, but the LLM-driven path is the intended UX.
class _ToolsChatHint extends StatelessWidget {
  const _ToolsChatHint({required this.samplePrompt});
  final String samplePrompt;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.all(VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.chat_outlined, size: 12, color: c.mintDim),
              const SizedBox(width: VbuTokens.space2),
              Text(
                'ASK THE CHAT',
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                  color: c.mintDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: VbuTokens.space1),
          SelectableText(
            samplePrompt,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Detail editor for a single `manifest.wiring.domainActions[]` entry.
/// Renders the entry's current `tool` / `icon` / `tooltip` (the same
/// values the host's domain icon row renders on the activity bar) so
/// the user sees the live wiring; the inline TextField fallbacks
/// autosave on every keystroke for users who already know the exact
/// edit. The intended path is the chat — the [_ToolsChatHint] block
/// suggests a sample prompt for an LLM round-trip.
class _DomainActionEditor extends StatefulWidget {
  const _DomainActionEditor({
    super.key,
    required this.entry,
    required this.allTools,
    required this.onUpdate,
    required this.onDelete,
  });
  final Map<String, dynamic> entry;
  final List<Map<String, dynamic>> allTools;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;
  @override
  State<_DomainActionEditor> createState() => _DomainActionEditorState();
}

class _DomainActionEditorState extends State<_DomainActionEditor> {
  late TextEditingController _tooltip;
  late TextEditingController _icon;
  late String _tool;

  @override
  void initState() {
    super.initState();
    _tooltip = TextEditingController(
      text: widget.entry['tooltip']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'tooltip': _tooltip.text}),
    );
    _icon = TextEditingController(
      text: widget.entry['icon']?.toString() ?? 'extension',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'icon': _icon.text}),
    );
    _tool = widget.entry['tool']?.toString() ?? '';
  }

  @override
  void dispose() {
    _tooltip.dispose();
    _icon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final toolNames =
        widget.allTools
            .map((t) => t['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Domain icon',
            subtitle: 'manifest.wiring.domainActions[]',
            kindPill: _tool.isEmpty ? null : 'tool: $_tool',
            onDelete: widget.onDelete,
            deleteLabel: 'Delete this domain icon entry',
          ),
          _ToolsChatHint(
            samplePrompt:
                'e.g. "Change the icon for $_tool to refresh and the '
                'tooltip to Reload data."',
          ),
          const SizedBox(height: VbuTokens.space4),
          _ToolsDetailSection(
            title: 'TOOL',
            body:
                toolNames.isEmpty
                    ? Text(
                      '(no tools defined yet — ask the chat to add one)',
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 11,
                        color: c.textTertiary,
                      ),
                    )
                    : VbuLabelledMenu<String>(
                      label: 'tool',
                      value:
                          toolNames.contains(_tool) ? _tool : toolNames.first,
                      options: toolNames,
                      onChanged: (v) {
                        setState(() => _tool = v);
                        widget.onUpdate(<String, dynamic>{'tool': v});
                      },
                    ),
          ),
          _ToolsDetailSection(
            title: 'TOOLTIP',
            body: VbuLabelledField(
              label: 'tooltip',
              controller: _tooltip,
              hint: 'hover label',
            ),
          ),
          _ToolsDetailSection(
            title: 'ICON (material name)',
            body: VbuLabelledField(
              label: 'icon',
              controller: _icon,
              hint: 'extension',
            ),
          ),
        ],
      ),
    );
  }
}

/// Detail editor for a single `manifest.wiring.lifecycle[]` entry.
/// Lifecycle slots route the chrome system buttons (project.new /
/// project.save / edit.undo / history.show / project.export / ...) to
/// a registered tool. The slot is canonically fixed by the host's
/// chrome — only the bound tool is user-editable. Inline `tool`
/// dropdown autosaves on change; canonical authoring path is the chat.
class _LifecycleEntryEditor extends StatefulWidget {
  const _LifecycleEntryEditor({
    super.key,
    required this.entry,
    required this.allTools,
    required this.onUpdate,
    required this.onDelete,
  });
  final Map<String, dynamic> entry;
  final List<Map<String, dynamic>> allTools;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;
  @override
  State<_LifecycleEntryEditor> createState() => _LifecycleEntryEditorState();
}

class _LifecycleEntryEditorState extends State<_LifecycleEntryEditor> {
  late String _tool;

  @override
  void initState() {
    super.initState();
    _tool = widget.entry['tool']?.toString() ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final slot = widget.entry['slot']?.toString() ?? '(slot)';
    final toolNames =
        widget.allTools
            .map((t) => t['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Lifecycle slot',
            subtitle: 'manifest.wiring.lifecycle[]',
            kindPill: _tool.isEmpty ? null : 'tool: $_tool',
            onDelete: widget.onDelete,
            deleteLabel: 'Unwire this slot',
          ),
          _ToolsChatHint(
            samplePrompt: 'e.g. "Wire the $slot slot to a different tool."',
          ),
          const SizedBox(height: VbuTokens.space4),
          _ToolsDetailSection(
            title: 'SLOT',
            body: Text(
              slot,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.textPrimary,
              ),
            ),
          ),
          _ToolsDetailSection(
            title: 'TOOL',
            body:
                toolNames.isEmpty
                    ? Text(
                      '(no tools defined yet — ask the chat to add one)',
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 11,
                        color: c.textTertiary,
                      ),
                    )
                    : VbuLabelledMenu<String>(
                      label: 'tool',
                      value:
                          toolNames.contains(_tool) ? _tool : toolNames.first,
                      options: toolNames,
                      onChanged: (v) {
                        setState(() => _tool = v);
                        widget.onUpdate(<String, dynamic>{'tool': v});
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

/// Detail editor for a single `manifest.chat.slashCommands[]` entry.
/// Two flavours — TEMPLATE (chip pre-fills the composer) or
/// DIRECT-DISPATCH (chip fires the bound tool immediately when set
/// `tool` is non-empty). Inline fallback fields autosave each
/// keystroke; the canonical authoring path is the chat.
class _SlashCommandEditor extends StatefulWidget {
  const _SlashCommandEditor({
    super.key,
    required this.entry,
    required this.allTools,
    required this.onUpdate,
    required this.onDelete,
  });
  final Map<String, dynamic> entry;
  final List<Map<String, dynamic>> allTools;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;
  @override
  State<_SlashCommandEditor> createState() => _SlashCommandEditorState();
}

class _SlashCommandEditorState extends State<_SlashCommandEditor> {
  late TextEditingController _command;
  late TextEditingController _description;
  late TextEditingController _template;
  late String _tool;

  @override
  void initState() {
    super.initState();
    _command = TextEditingController(
      text: widget.entry['command']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'command': _command.text}),
    );
    _description = TextEditingController(
      text: widget.entry['description']?.toString() ?? '',
    )..addListener(
      () =>
          widget.onUpdate(<String, dynamic>{'description': _description.text}),
    );
    _template = TextEditingController(
      text: widget.entry['template']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'template': _template.text}),
    );
    _tool = widget.entry['tool']?.toString() ?? '';
  }

  @override
  void dispose() {
    _command.dispose();
    _description.dispose();
    _template.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final toolNames =
        widget.allTools
            .map((t) => t['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
    // '<none>' sentinel = template chip (no direct dispatch).
    const noneOpt = '<none — template only>';
    final toolOptions = <String>[noneOpt, ...toolNames];
    final selected =
        _tool.isEmpty ? noneOpt : (toolNames.contains(_tool) ? _tool : noneOpt);
    final flavour =
        _tool.isEmpty ? 'flavour: template' : 'flavour: direct-dispatch';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Slash command',
            subtitle: 'manifest.chat.slashCommands[]',
            kindPill: flavour,
            onDelete: widget.onDelete,
            deleteLabel: 'Delete this slash command',
          ),
          _ToolsChatHint(
            samplePrompt:
                'e.g. "Make ${_command.text.isEmpty ? '/cmd' : _command.text} '
                'a direct-dispatch chip that fires '
                '${toolNames.isEmpty ? "my_tool" : toolNames.first} with no args."',
          ),
          const SizedBox(height: VbuTokens.space4),
          _ToolsDetailSection(
            title: 'COMMAND',
            body: VbuLabelledField(
              label: 'command',
              controller: _command,
              hint: '/cmd',
            ),
          ),
          _ToolsDetailSection(
            title: 'DESCRIPTION',
            body: VbuLabelledField(
              label: 'desc',
              controller: _description,
              hint: 'what the chip does',
            ),
          ),
          _ToolsDetailSection(
            title: 'TOOL (direct dispatch)',
            body: VbuLabelledMenu<String>(
              label: 'tool',
              value: selected,
              options: toolOptions,
              onChanged: (v) {
                final newTool = v == noneOpt ? '' : v;
                setState(() => _tool = newTool);
                widget.onUpdate(<String, dynamic>{'tool': newTool});
              },
            ),
          ),
          _ToolsDetailSection(
            title: 'TEMPLATE (chip prefill)',
            body: VbuLabelledField(
              label: 'template',
              controller: _template,
              hint: 'pre-fills the composer (optional)',
            ),
          ),
          Text(
            _tool.isEmpty
                ? 'Template chip — submitting the chip just pre-fills the '
                    'composer with the template; the LLM interprets the '
                    'rest.'
                : 'Direct-dispatch chip — submitting the chip fires the '
                    'bound tool directly, bypassing the LLM. The template '
                    'is only a visual placeholder in this flavour.',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              color: c.textTertiary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Detail editor for a `manifest.settings.sections[]` entry — label
/// editing + per-section delete + add-field hook. Fields are listed in
/// the left navigator under their parent section (clicking a field row
/// opens the [_SettingsFieldEditor]); this editor is the section
/// "overview" surface.
class _SettingsSectionEditor extends StatefulWidget {
  const _SettingsSectionEditor({
    super.key,
    required this.section,
    required this.overridesFile,
    required this.onUpdate,
    required this.onDelete,
    required this.onAddField,
  });
  final Map<String, dynamic> section;
  final String overridesFile;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;
  final VoidCallback onAddField;
  @override
  State<_SettingsSectionEditor> createState() => _SettingsSectionEditorState();
}

class _SettingsSectionEditorState extends State<_SettingsSectionEditor> {
  late TextEditingController _label;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(
      text: widget.section['label']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'label': _label.text}),
    );
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final key = widget.section['key']?.toString() ?? '';
    final fields =
        (widget.section['fields'] is List)
            ? (widget.section['fields'] as List).whereType<Map>().length
            : 0;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Settings section',
            subtitle: 'manifest.settings.sections[]',
            kindPill: 'key: $key  ·  $fields fields',
            onDelete: widget.onDelete,
            deleteLabel: 'Delete this settings section',
          ),
          _ToolsChatHint(
            samplePrompt:
                'e.g. "Add a toggle field named auto_refresh to the '
                '${key.isEmpty ? 'general' : key} section, defaulting to '
                'true."',
          ),
          const SizedBox(height: VbuTokens.space4),
          _ToolsDetailSection(
            title: 'LABEL',
            body: VbuLabelledField(
              label: 'label',
              controller: _label,
              hint: 'section header text',
            ),
          ),
          _ToolsDetailSection(
            title: 'KEY (immutable)',
            body: Text(
              key,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textSecondary,
              ),
            ),
          ),
          _ToolsDetailSection(
            title: 'FIELDS — $fields',
            body: TextButton.icon(
              onPressed: widget.onAddField,
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add field'),
            ),
          ),
          Text(
            'Each field is editable in its own row in the left '
            'navigator under this section.',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 10,
              color: c.textTertiary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: VbuTokens.space5),
          _ToolsDetailSection(
            title: 'PREVIEW — how this section will render',
            body: _SettingsSectionsPreview(
              sections: <Map<String, dynamic>>[widget.section],
              overridesFile: widget.overridesFile,
            ),
          ),
        ],
      ),
    );
  }
}

/// Detail editor for a single field inside a settings section — key
/// (immutable identity), label, type (text/toggle/menu/number), default
/// value, and (for menu) options. Edits autosave to manifest; *values*
/// the end-user sets at runtime go to a separate per-package overrides
/// file (same file the legacy gear dialog used) so manifest defaults
/// and effective values stay distinct.
class _SettingsFieldEditor extends StatefulWidget {
  const _SettingsFieldEditor({
    super.key,
    required this.field,
    required this.overridesFile,
    required this.onUpdate,
    required this.onDelete,
  });
  final Map<String, dynamic> field;
  final String overridesFile;
  final void Function(Map<String, dynamic> patch) onUpdate;
  final VoidCallback onDelete;
  @override
  State<_SettingsFieldEditor> createState() => _SettingsFieldEditorState();
}

class _SettingsFieldEditorState extends State<_SettingsFieldEditor> {
  late TextEditingController _label;
  late TextEditingController _value;
  late TextEditingController _options;
  late String _type;

  static const _types = <String>['text', 'toggle', 'menu', 'number'];

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(
      text: widget.field['label']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'label': _label.text}),
    );
    _value = TextEditingController(
      text: widget.field['value']?.toString() ?? '',
    )..addListener(
      () => widget.onUpdate(<String, dynamic>{'value': _value.text}),
    );
    final opts = widget.field['options'];
    _options = TextEditingController(
      text: opts is List ? opts.map((e) => '$e').join(', ') : '',
    )..addListener(() {
      final parts =
          _options.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
      widget.onUpdate(<String, dynamic>{'options': parts});
    });
    final declared = widget.field['type']?.toString() ?? 'text';
    _type = _types.contains(declared) ? declared : 'text';
  }

  @override
  void dispose() {
    _label.dispose();
    _value.dispose();
    _options.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final key = widget.field['key']?.toString() ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(VbuTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ToolsDetailHeader(
            title: 'Settings field',
            subtitle: 'manifest.settings.sections[].fields[]',
            kindPill: 'key: $key  ·  type: $_type',
            onDelete: widget.onDelete,
            deleteLabel: 'Delete this field',
          ),
          _ToolsChatHint(
            samplePrompt:
                'e.g. "Rename the $key field to log_verbosity and make it '
                'a menu with options none, info, debug."',
          ),
          const SizedBox(height: VbuTokens.space4),
          _ToolsDetailSection(
            title: 'KEY (immutable)',
            body: Text(
              key,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textSecondary,
              ),
            ),
          ),
          _ToolsDetailSection(
            title: 'LABEL',
            body: VbuLabelledField(
              label: 'label',
              controller: _label,
              hint: 'display label',
            ),
          ),
          _ToolsDetailSection(
            title: 'TYPE',
            body: VbuLabelledMenu<String>(
              label: 'type',
              value: _type,
              options: _types,
              onChanged: (v) {
                setState(() => _type = v);
                widget.onUpdate(<String, dynamic>{'type': v});
              },
            ),
          ),
          _ToolsDetailSection(
            title: 'DEFAULT VALUE',
            body: VbuLabelledField(
              label: 'value',
              controller: _value,
              hint: 'manifest-declared default',
            ),
          ),
          if (_type == 'menu')
            _ToolsDetailSection(
              title: 'OPTIONS (comma-separated)',
              body: VbuLabelledField(
                label: 'options',
                controller: _options,
                hint: 'a, b, c',
              ),
            ),
        ],
      ),
    );
  }
}

/// Preview block for a single section's fields. Wraps
/// [_ManifestFieldList] inside a surface-2 card with a mono-caps
/// header so the editor's PREVIEW section visually mirrors the chrome
/// Settings dialog layout. Kept private to this file pending the
/// follow-up phase that lifts both this preview and the underlying
/// list into a shared base widget.
class _SettingsSectionsPreview extends StatelessWidget {
  const _SettingsSectionsPreview({
    required this.sections,
    required this.overridesFile,
  });
  final List<Map<String, dynamic>> sections;
  final String overridesFile;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '(no sections)',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final s in sections)
            Padding(
              padding: const EdgeInsets.only(bottom: VbuTokens.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: VbuTokens.space2),
                    child: Text(
                      ((s['label'] as String?) ?? 'section').toUpperCase(),
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                        color: c.textTertiary,
                      ),
                    ),
                  ),
                  _ManifestFieldList(
                    fields:
                        (s['fields'] as List<dynamic>? ?? const <dynamic>[])
                            .whereType<Map<String, dynamic>>()
                            .toList(),
                    overridesFile: overridesFile,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Renderer for a manifest-supplied settings section. Loads any prior
/// overrides from disk on mount, autosaves each edit. Per-field widgets
/// pick a control type from `field.type` (text · toggle); unknown
/// types fall back to read-only display.
class _ManifestFieldList extends StatefulWidget {
  const _ManifestFieldList({required this.fields, required this.overridesFile});
  final List<Map<String, dynamic>> fields;
  final String overridesFile;

  @override
  State<_ManifestFieldList> createState() => _ManifestFieldListState();
}

class _ManifestFieldListState extends State<_ManifestFieldList> {
  Map<String, dynamic> _overrides = <String, dynamic>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadOverrides();
  }

  Future<void> _loadOverrides() async {
    try {
      final f = File(widget.overridesFile);
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          if (mounted) {
            setState(() {
              _overrides = json;
              _loaded = true;
            });
          }
          return;
        }
      }
    } catch (_) {
      /* fall through to defaults */
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _persist() async {
    try {
      final f = File(widget.overridesFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_overrides));
    } catch (_) {
      /* best-effort */
    }
  }

  void _setOverride(String key, Object? value) {
    setState(() {
      if (value == null || (value is String && value.isEmpty)) {
        _overrides.remove(key);
      } else {
        _overrides[key] = value;
      }
    });
    // ignore: unawaited_futures
    _persist();
  }

  Object? _effectiveValue(Map<String, dynamic> field) {
    final key = field['key'] as String?;
    if (key != null && _overrides.containsKey(key)) {
      final v = _overrides[key];
      if (v != null && !(v is String && v.isEmpty)) return v;
    }
    return field['value'];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fields.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '(no fields)',
          style: TextStyle(fontSize: 11, color: Color(0xFF6E7681)),
        ),
      );
    }
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Loading…',
          style: TextStyle(fontSize: 11, color: Color(0xFF6E7681)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final f in widget.fields)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _fieldRow(f),
          ),
      ],
    );
  }

  Widget _fieldRow(Map<String, dynamic> field) {
    final key = field['key'] as String?;
    if (key == null) {
      final label = (field['label'] as String?) ?? '?';
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const SizedBox(width: 92),
          Expanded(
            child: Text(
              '(missing key) — $label',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFF6E7681),
              ),
            ),
          ),
        ],
      );
    }
    return ManifestFieldRow(
      field: field,
      value: _effectiveValue(field),
      onChanged: (v) => _setOverride(key, v),
    );
  }
}
