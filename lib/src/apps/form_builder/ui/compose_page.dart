import 'dart:convert' show JsonEncoder, jsonDecode;
import 'dart:io';

import 'package:appplayer_form_view/appplayer_form_view.dart';
import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart'
    show BuiltinToolRegistry, VibeTokens, vibeMono;
import 'package:mcp_bundle/mcp_bundle.dart'
    show FormDocument, FormDocumentMetadata, FormSection, FormTableBlock;
import 'package:path/path.dart' as p;

import '../init/form_init.dart';
import 'form_tool_client.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Fill a template → validate → save draft → issue, ON THE FORM:
/// the live sheet sits in the middle, the right panel is VISUAL input —
/// one text field per schema field and a row editor per table (add /
/// remove rows, type into cells) — and every keystroke re-renders the
/// sheet. No JSON typing; the engine document is materialised
/// (`form.create_document` + per-table `form.patch`) at action time.
class ComposePage extends StatefulWidget {
  const ComposePage({
    super.key,
    required this.server,
    required this.init,
    this.correction,
  });

  final BuiltinToolRegistry server;
  final FormInit init;

  /// When set (Issues -> "correct & reissue"), the editor opens PRE-FILLED
  /// with the issued snapshot's template + data (+ table rows recovered
  /// from the frozen uiDsl artifact) and the eventual issue carries
  /// `supersedes: correction['issueId']`.
  final Map<String, dynamic>? correction;

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  late Future<List<Map<String, dynamic>>> _drafts;

  // --- editor state ---------------------------------------------------------
  Map<String, dynamic>? _tpl; // full template JSON
  String? _loadedDraftDocumentId;
  String _statusLine = '';
  String? _supersedes;

  /// One controller per schema field.
  final Map<String, TextEditingController> _fields = {};

  /// Controller whose writes re-render the sheet — human keystrokes AND
  /// programmatic `studio.ui.type` (which bypasses onChanged).
  TextEditingController _liveCtrl(String text) {
    final c = TextEditingController(text: text);
    c.addListener(() {
      if (mounted) setState(() {});
    });
    return c;
  }
  final Map<String, FocusNode> _fieldFocus = {};

  /// Table editor state: blockId → rows → colId → controller.
  final Map<String, List<Map<String, TextEditingController>>> _tables = {};

  /// Issue output media — PDF is the print canonical and defaults ON;
  /// the in-app as-issued record is always frozen regardless.
  final Set<String> _issueFormats = {'pdf'};

  String? get _templateId => _tpl?['templateId'] as String?;
  String? get _templateVersion => _tpl?['version'] as String?;

  @override
  void initState() {
    super.initState();
    _drafts = widget.init.listDrafts();
    final correction = widget.correction;
    if (correction != null) {
      _statusLine =
          'Correction - issuing will supersede ${correction['issueId']}';
      _supersedes = correction['issueId'] as String?;
      // Async prefill: template JSON + frozen data (+ table rows from the
      // frozen uiDsl artifact, which carries form.patch results).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prefillFromCorrection(correction);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    for (final f in _fieldFocus.values) {
      f.dispose();
    }
    _disposeTables();
    super.dispose();
  }

  void _disposeTables() {
    for (final rows in _tables.values) {
      for (final row in rows) {
        for (final c in row.values) {
          c.dispose();
        }
      }
    }
    _tables.clear();
  }

  void _refreshDrafts() {
    // Block body — an arrow closure would return the Future and trip the
    // setState assert (see templates_page._refresh).
    final next = widget.init.listDrafts();
    setState(() {
      _drafts = next;
    });
  }

  void _note(String message) {
    if (mounted) setState(() => _statusLine = message);
  }

  // --- template loading ------------------------------------------------------

  /// Load a template and (re)build the visual editors: field controllers
  /// from the schema, table editors seeded with the template's own rows
  /// (they are the example/default content).
  Future<void> _loadTemplate(
    String templateId, {
    Map<String, dynamic> data = const {},
    Map<String, List<Map<String, String>>>? tableRows,
  }) async {
    try {
      final out = await callFormTool(widget.server, 'form.get_template', {
        'templateId': templateId,
      });
      final tpl = (out['template'] as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _tpl = tpl;
        for (final c in _fields.values) {
          c.dispose();
        }
        for (final f in _fieldFocus.values) {
          f.dispose();
        }
        _fields.clear();
        _fieldFocus.clear();
        final fields =
            (((tpl['schema'] as Map?)?['fields'] as List?) ?? const [])
                .cast<Map>();
        for (final f in fields) {
          final name = f['name'] as String;
          _fields[name] = _liveCtrl('${data[name] ?? ''}');
          _fieldFocus[name] = FocusNode();
        }
        _disposeTables();
        for (final t in _templateTables(tpl)) {
          final blockId = t.$1;
          final columns = t.$2;
          final defaultRows = t.$3;
          final seed = tableRows?[blockId] ??
              [
                for (final r in defaultRows)
                  {
                    for (final col in columns)
                      col: '${(r['cells'] as Map?)?[col] ?? ''}',
                  },
              ];
          _tables[blockId] = [
            for (final r in seed)
              {
                for (final col in columns) col: _liveCtrl(r[col] ?? ''),
              },
          ];
        }
      });
    } catch (e) {
      _note('$e');
    }
  }

  /// (blockId, columnIds, defaultRows) per table block in the template.
  List<(String, List<String>, List<Map<String, dynamic>>)> _templateTables(
    Map<String, dynamic> tpl,
  ) {
    final out = <(String, List<String>, List<Map<String, dynamic>>)>[];
    for (final sec in ((tpl['defaultSections'] as List?) ?? const [])
        .cast<Map>()) {
      for (final b in ((sec['blocks'] as List?) ?? const []).cast<Map>()) {
        if (b['type'] == 'table') {
          out.add((
            '${b['blockId']}',
            [
              for (final c in ((b['columns'] as List?) ?? const []).cast<Map>())
                '${c['id']}',
            ],
            ((b['rows'] as List?) ?? const []).cast<Map>().map((m) {
              return m.cast<String, dynamic>();
            }).toList(),
          ));
        }
      }
    }
    return out;
  }

  Future<void> _pickTemplate() async {
    try {
      final out = await callFormTool(widget.server, 'form.list_templates', {
        'limit': 100,
      });
      if (!mounted) return;
      final templates = ((out['templates'] as List?) ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Template'),
          children: [
            for (final t in templates)
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.of(ctx).pop(t['templateId'] as String),
                child: Text('${t['name']} · ${t['templateId']}'),
              ),
            if (templates.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No templates — create one in Templates first.'),
              ),
          ],
        ),
      );
      if (picked != null) await _loadTemplate(picked);
    } catch (e) {
      _note('$e');
    }
  }

  Future<void> _prefillFromCorrection(Map<String, dynamic> correction) async {
    final content =
        (correction['content'] as Map?)?.cast<String, dynamic>() ?? const {};
    final templateId = content['templateId'] as String?;
    if (templateId == null) return;
    // Table rows come back from the frozen uiDsl artifact (the only freeze
    // that carries per-document form.patch results).
    Map<String, List<Map<String, String>>>? tableRows;
    try {
      for (final a
          in ((correction['artifacts'] as List?) ?? const []).cast<Map>()) {
        if (a['format'] != 'uiDsl') continue;
        final path = p.join(widget.init.projectRoot, a['locator'] as String);
        final tree = jsonDecode(File(path).readAsStringSync());
        if (tree is! Map) break;
        final doc = formDocumentFromUiDsl(tree.cast<String, dynamic>());
        tableRows = {
          for (final sec in doc.sections)
            for (final b in sec.blocks)
              if (b is FormTableBlock)
                b.blockId: [
                  for (final r in b.rows)
                    {
                      for (final e in r.cells.entries) e.key: '${e.value}',
                    },
                ],
        };
        break;
      }
    } catch (_) {
      tableRows = null;
    }
    await _loadTemplate(
      templateId,
      data: (content['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      tableRows: tableRows,
    );
  }

  // --- live document assembly -------------------------------------------------

  Map<String, dynamic> _currentData() => <String, dynamic>{
        for (final e in _fields.entries) e.key: e.value.text,
      };

  List<Map<String, dynamic>> _currentTableRows(String blockId) {
    return [
      for (final row in _tables[blockId] ?? const [])
        {
          'cells': {for (final e in row.entries) e.key: e.value.text},
        },
    ];
  }

  /// The live preview document: template sections with the table editors'
  /// rows swapped in, plus the current field values.
  FormDocument? _assembleDoc() {
    final tpl = _tpl;
    if (tpl == null) return null;
    final sections = <FormSection>[];
    for (final sec in ((tpl['defaultSections'] as List?) ?? const [])
        .cast<Map>()) {
      final secJson = jsonDecode(jsonEncodeSafe(sec)) as Map<String, dynamic>;
      for (final b in ((secJson['blocks'] as List?) ?? const []).cast<Map>()) {
        if (b['type'] == 'table' && _tables.containsKey(b['blockId'])) {
          b['rows'] = _currentTableRows('${b['blockId']}');
        }
      }
      sections.add(FormSection.fromJson(secJson));
    }
    return FormDocument(
      documentId: 'compose',
      templateId: '${tpl['templateId']}',
      templateVersion: '${tpl['version']}',
      metadata: FormDocumentMetadata(
        author: 'compose',
        createdAt: DateTime.now(),
      ),
      sections: sections,
      data: _currentData(),
    );
  }

  // --- engine actions ----------------------------------------------------------

  /// Materialise a fresh engine document: create with the field data, then
  /// patch every table's rows in (tables are per-DOCUMENT content).
  Future<String?> _materialise() async {
    final tpl = _tpl;
    if (tpl == null) {
      _note('Pick a template first');
      return null;
    }
    final out = await callFormTool(widget.server, 'form.create_document', {
      'templateId': _templateId,
      'data': _currentData(),
    });
    final documentId = out['documentId'] as String?;
    if (documentId == null) return null;
    // Patch table rows by section/block position.
    final sections =
        ((tpl['defaultSections'] as List?) ?? const []).cast<Map>();
    final patches = <Map<String, dynamic>>[];
    for (var s = 0; s < sections.length; s++) {
      final blocks = ((sections[s]['blocks'] as List?) ?? const []).cast<Map>();
      for (var b = 0; b < blocks.length; b++) {
        final blockId = '${blocks[b]['blockId']}';
        if (blocks[b]['type'] == 'table' && _tables.containsKey(blockId)) {
          patches.add({
            'op': 'replace',
            'path': '/sections/$s/blocks/$b/rows',
            'value': _currentTableRows(blockId),
          });
        }
      }
    }
    if (patches.isNotEmpty) {
      await callFormTool(widget.server, 'form.patch', {
        'documentId': documentId,
        'patches': patches,
      });
    }
    return documentId;
  }

  Future<void> _validate() async {
    try {
      final documentId = await _materialise();
      if (documentId == null) return;
      final out = await callFormTool(widget.server, 'form.validate', {
        'documentId': documentId,
      });
      final ok = out['isValid'] == true;
      final issues = (out['issues'] as List?) ?? const [];
      _note(ok
          ? 'Valid — no issues.'
          : 'Validation: ${_pretty.convert(issues)}');
    } catch (e) {
      _note('$e');
    }
  }

  Future<String?> _persistDraft() async {
    final documentId = await _materialise();
    if (documentId == null) return null;
    await callFormTool(widget.server, 'form_builder.draft_save', {
      'documentId': documentId,
      'templateId': _templateId,
      if (_templateVersion != null) 'templateVersion': _templateVersion,
      'data': _currentData(),
      'tables': {
        for (final blockId in _tables.keys)
          blockId: [
            for (final row in _tables[blockId]!)
              {for (final e in row.entries) e.key: e.value.text},
          ],
      },
    });
    final previous = _loadedDraftDocumentId;
    if (previous != null && previous != documentId) {
      await callFormTool(widget.server, 'form_builder.draft_delete', {
        'documentId': previous,
      });
    }
    _loadedDraftDocumentId = documentId;
    return documentId;
  }

  Future<void> _saveDraft() async {
    try {
      final documentId = await _persistDraft();
      if (documentId == null) return;
      _note('Draft saved ($documentId)');
      _refreshDrafts();
    } catch (e) {
      _note('$e');
    }
  }

  /// 상신 — save the draft, then open an approval line over it
  /// (`form_builder.approval_request`; button = tool 1:1). The line is
  /// typed as ordered approver ids; progress/acting lives on the
  /// Approvals route.
  Future<void> _requestApproval() async {
    final titleCtrl = TextEditingController();
    final lineCtrl = TextEditingController();
    final byCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Request approval (상신)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: '기안 제목 (선택)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: byCtrl,
              decoration: const InputDecoration(
                labelText: '기안자 (requestedBy)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: lineCtrl,
              decoration: const InputDecoration(
                labelText: '결재라인 — 승인자 id 순서대로, 쉼표 구분'
                    ' (예: dept-lead, owner)',
                border: OutlineInputBorder(),
              ),
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
            child: const Text('상신'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final documentId = await _persistDraft();
      if (documentId == null) return;
      final line = [
        for (final id in lineCtrl.text.split(','))
          if (id.trim().isNotEmpty) {'approverId': id.trim()},
      ];
      final out = await callFormTool(
        widget.server,
        'form_builder.approval_request',
        {
          'documentId': documentId,
          'requestedBy':
              byCtrl.text.trim().isEmpty ? 'owner' : byCtrl.text.trim(),
          if (titleCtrl.text.trim().isNotEmpty) 'title': titleCtrl.text.trim(),
          'line': line,
        },
      );
      _note(
        '상신 완료 — 현재 결재자 '
        '${(out['line'] as List).cast<Map>().first['approverId']}'
        ' (Approvals 탭에서 진행)',
      );
      _refreshDrafts();
    } catch (e) {
      _note('$e');
    }
  }

  Future<void> _issue() async {
    try {
      final documentId = await _persistDraft();
      if (documentId == null) return;
      if (_issueFormats.isEmpty) {
        _note('Pick at least one issue format (PDF/HTML/Markdown).');
        return;
      }
      final out = await callFormTool(widget.server, 'form_builder.issue', {
        'documentId': documentId,
        'formats': _issueFormats.toList(),
        if (_supersedes != null) 'supersedes': _supersedes,
      });
      _note('Issued ${out['issueNumber']} → ${out['artifacts']}');
      if (mounted) setState(() => _supersedes = null);
      _refreshDrafts();
    } catch (e) {
      _note('$e');
    }
  }

  Future<void> _loadDraft(Map<String, dynamic> draft) async {
    final document =
        (draft['document'] as Map?)?.cast<String, dynamic>() ?? const {};
    final templateId = document['templateId'] as String?;
    if (templateId == null) return;
    final tables = (document['tables'] as Map?)?.cast<String, dynamic>();
    await _loadTemplate(
      templateId,
      data: (document['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      tableRows: tables == null
          ? null
          : {
              for (final e in tables.entries)
                e.key: [
                  for (final r in (e.value as List).cast<Map>())
                    {
                      for (final c in r.entries) '${c.key}': '${c.value}',
                    },
                ],
            },
    );
    if (mounted) {
      setState(() {
        _loadedDraftDocumentId = draft['documentId'] as String?;
        _statusLine = 'Loaded draft ${draft['documentId']}';
      });
    }
  }

  // --- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _assembleDoc();
    final pageSize =
        ((_tpl?['layoutPolicy'] as Map?)?['pageSize'] as Map?)
            ?.cast<String, dynamic>();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 240, child: _draftsList(theme)),
        const VerticalDivider(width: 1),
        Expanded(
          child: doc != null
              ? FormView(
                  document: doc,
                  imageBaseDir: widget.init.projectRoot,
                  pageWidthMm: (pageSize?['width'] as num?)?.toDouble() ?? 210,
                  pageHeightMm:
                      (pageSize?['height'] as num?)?.toDouble() ?? 297,
                  onBlockTap: (ref) {
                    // Tap a field on the sheet → focus its input.
                    final b = ref.block;
                    final json = b.toJson();
                    final fieldName = json['fieldName'];
                    if (fieldName is String &&
                        _fieldFocus[fieldName] != null) {
                      _fieldFocus[fieldName]!.requestFocus();
                    }
                  },
                )
              : const Center(
                  child: Text('Pick a template — fill it on the form.'),
                ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(width: 340, child: _inputPanel(theme)),
      ],
    );
  }

  Widget _draftsList(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Text('Drafts', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                tooltip: 'Reload',
                onPressed: _refreshDrafts,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _drafts,
            builder: (context, snap) {
              final items = snap.data;
              if (snap.hasError) {
                return Center(child: Text('${snap.error}'));
              }
              if (items == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (items.isEmpty) {
                return const Center(child: Text('No drafts'));
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final d = items[i];
                  final doc =
                      (d['document'] as Map?)?.cast<String, dynamic>();
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.drafts_outlined, size: 18),
                    title: Text(
                      '${doc?['templateId'] ?? '?'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${d['status']} · ${d['updatedAt'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _loadDraft(d),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// The VISUAL input panel: template picker, one input per schema field,
  /// a row editor per table, actions. Every keystroke re-renders the sheet.
  Widget _inputPanel(ThemeData theme) {
    final c = VibeTokens.colorOf(context);
    final fields = (((_tpl?['schema'] as Map?)?['fields'] as List?) ??
            const [])
        .cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickTemplate,
                  icon: const Icon(Icons.grid_view_outlined, size: 16),
                  label: Text(
                    _templateId ?? 'Pick template',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_supersedes != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: InputChip(
              avatar: const Icon(Icons.published_with_changes, size: 16),
              label: Text(
                'correction of $_supersedes',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => setState(() => _supersedes = null),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              if (fields.isNotEmpty) ...[
                _sectionHeader('FIELDS', c),
                for (final f in fields)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: TextField(
                      controller: _fields[f['name']],
                      focusNode: _fieldFocus[f['name']],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: '${f['name']}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
              for (final t in _templateTables(_tpl ?? const {})) ...[
                _sectionHeader('TABLE · ${t.$1}'.toUpperCase(), c),
                _tableEditor(t.$1, t.$2, theme, c),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(
            spacing: 6,
            children: [
              for (final f in const ['pdf', 'html', 'markdown', 'image'])
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(f),
                  selected: _issueFormats.contains(f),
                  onSelected: (v) => setState(() {
                    v ? _issueFormats.add(f) : _issueFormats.remove(f);
                  }),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          // Wrap, not Row: three buttons overflow the 340px panel on
          // compact densities (widget-test caught a 140px overflow).
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: _tpl == null ? null : _validate,
                child: const Text('Validate'),
              ),
              OutlinedButton(
                onPressed: _tpl == null ? null : _saveDraft,
                child: const Text('Save draft'),
              ),
              OutlinedButton.icon(
                onPressed: _tpl == null ? null : _requestApproval,
                icon: const Icon(Icons.approval_outlined, size: 16),
                label: const Text('상신'),
              ),
              FilledButton.icon(
                onPressed: _tpl == null ? null : _issue,
                icon: const Icon(Icons.verified_outlined, size: 16),
                label: const Text('Issue'),
              ),
            ],
          ),
        ),
        if (_statusLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SelectableText(
              _statusLine,
              maxLines: 5,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _sectionHeader(String title, dynamic c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
      child: Text(
        title,
        style: vibeMono(size: 10, color: c.textSecondary)
            .copyWith(letterSpacing: 1.1),
      ),
    );
  }

  /// Row editor — the way TABLE CONTENT gets filled: one compact text
  /// field per cell, add/remove rows; the sheet re-renders as you type
  /// and `form.patch` carries the rows into the real document at
  /// validate/draft/issue time.
  Widget _tableEditor(
    String blockId,
    List<String> columns,
    ThemeData theme,
    dynamic c,
  ) {
    final rows = _tables[blockId] ?? const [];
    final colTitles = <String, String>{};
    for (final t in _templateTables(_tpl ?? const {})) {
      if (t.$1 != blockId) continue;
      for (final sec in ((_tpl?['defaultSections'] as List?) ?? const [])
          .cast<Map>()) {
        for (final b in ((sec['blocks'] as List?) ?? const []).cast<Map>()) {
          if ('${b['blockId']}' == blockId) {
            for (final col
                in ((b['columns'] as List?) ?? const []).cast<Map>()) {
              colTitles['${col['id']}'] = '${col['title'] ?? col['id']}';
            }
          }
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          'row ${r + 1}',
                          style: vibeMono(size: 10, color: c.textSecondary),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => setState(() {
                            for (final ctrl in rows[r].values) {
                              ctrl.dispose();
                            }
                            _tables[blockId]!.removeAt(r);
                          }),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final col in columns)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: TextField(
                          controller: rows[r][col],
                          onChanged: (_) => setState(() {}),
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: colTitles[col] ?? col,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _tables[blockId]!.add({
                  for (final col in columns) col: _liveCtrl(''),
                });
              }),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add row'),
            ),
          ),
        ],
      ),
    );
  }
}

/// jsonEncode that tolerates the Map subtypes tool envelopes produce.
String jsonEncodeSafe(Object? value) => const JsonEncoder().convert(value);
