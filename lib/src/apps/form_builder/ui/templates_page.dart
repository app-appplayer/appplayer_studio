import 'dart:async';
import 'dart:convert' show JsonEncoder, jsonDecode;

import 'package:appplayer_form_view/appplayer_form_view.dart';
import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart'
    show ScopedDialogs, BuiltinToolRegistry, VibeTokens, inspectTag, vibeMono;
import 'package:mcp_bundle/mcp_bundle.dart'
    show
        FormBlock,
        FormDocument,
        FormDocumentMetadata,
        FormFieldBlock,
        FormHeadingBlock,
        FormImageBlock,
        FormSection,
        FormTableBlock,
        FormTextBlock;

import '../infra/form_spec_vocab.dart' show kPlacementAnchors;
import 'form_tool_client.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Starter skeleton for a new template — the mcp_bundle `FormTemplate`
/// canonical JSON. Authoring is conversational-first (the manager edits
/// templates through chat); this editor is the expert/manual path.
String _newTemplateSkeleton() => _pretty.convert(<String, dynamic>{
  'templateId': 'my-template',
  'version': '1.0.0',
  'name': 'My template',
  'schema': <String, dynamic>{
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{'name': 'title', 'type': 'string'},
    ],
  },
  'defaultSections': <Map<String, dynamic>>[
    <String, dynamic>{
      'sectionId': 'main',
      'index': 0,
      'blocks': <Map<String, dynamic>>[
        <String, dynamic>{
          'blockId': 'h1',
          'type': 'heading',
          'index': 0,
          'level': 1,
          'content': 'Title',
        },
        <String, dynamic>{
          'blockId': 'f1',
          'type': 'formField',
          'index': 1,
          'fieldName': 'title',
          'fieldType': 'text',
        },
      ],
    },
  ],
  'layoutPolicy': <String, dynamic>{
    'pageSize': <String, dynamic>{'size': 'A4', 'width': 210, 'height': 297},
    'margins': <String, dynamic>{
      'top': 20,
      'right': 20,
      'bottom': 20,
      'left': 20,
    },
    'fontPolicy': <String, dynamic>{
      'defaultFont': 'sans-serif',
      'defaultSize': 12,
      'headingSize': 18,
      'bodySize': 12,
      'minSize': 8,
    },
  },
});

/// Templates — master list (left) + LIVE FORM PANEL (right).
///
/// The panel is not a modal: the chat stays usable next to it, so the
/// operator edits a template BY CONVERSATION while watching the form
/// ("put a navy outline on the title…") — the panel polls the current
/// version and re-renders when the manager saves a new one. Every action
/// is a `form.*` tool call; JSON editing is the expert path.
class TemplatesPage extends StatefulWidget {
  const TemplatesPage({
    super.key,
    required this.server,
    required this.projectRoot,
  });
  final BuiltinToolRegistry server;

  /// Preview images (`stamp.png` &co) resolve against the project root.
  final String projectRoot;

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> with ScopedDialogs {
  late Future<List<Map<String, dynamic>>> _templates;
  final TextEditingController _search = TextEditingController();

  // --- selection + live panel state ---------------------------------------
  String? _selectedId;
  Map<String, dynamic>? _tpl; // full template JSON of the selection
  FormDocument? _previewDoc; // locally assembled placeholder-fill document
  FormBlockRef? _inspected; // tapped block → properties panel (editor seed)
  bool _dirty = false; // inspector edits pending a version save
  bool _metrics = false; // mm rulers + page-size label on the sheet
  String? _panelError;
  int _panelTab = 0; // 0 Preview · 1 Fields · 2 Structure

  /// Version poller — the "watch while you edit by chat" loop. When the
  /// manager (or an external LLM) saves a new version of the selected
  /// template, the panel re-renders on its own.
  Timer? _versionPoll;

  @override
  void initState() {
    super.initState();
    _templates = _load();
    _versionPoll = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkVersion(),
    );
  }

  @override
  void dispose() {
    _versionPoll?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final out = await callFormTool(widget.server, 'form.list_templates', {
      'limit': 100,
    });
    return ((out['templates'] as List?) ?? const [])
        .cast<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  void _refresh() {
    // NOT `setState(() => _templates = _load())`: an arrow closure RETURNS
    // the assignment's value (a Future), tripping the framework's
    // "setState callback returned a Future" assert and killing the caller
    // (create-then-refresh silently never refreshed — widget-test caught).
    final next = _load();
    setState(() {
      _templates = next;
    });
  }

  Future<void> _showError(Object e) async {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('$e')));
  }

  // --- live panel -----------------------------------------------------------

  Future<void> _select(String templateId) async {
    setState(() {
      _selectedId = templateId;
      _tpl = null;
      _previewDoc = null;
      _inspected = null;
      _dirty = false;
      _panelError = null;
    });
    await _loadPanel(templateId);
  }

  Future<void> _loadPanel(String templateId) async {
    try {
      final out = await callFormTool(widget.server, 'form.get_template', {
        'templateId': templateId,
      });
      final tpl = (out['template'] as Map).cast<String, dynamic>();
      if (!mounted || _selectedId != templateId) return;
      setState(() {
        _tpl = tpl;
        _previewDoc = _assemblePreview(tpl);
        _panelError = null;
      });
    } catch (e) {
      if (mounted && _selectedId == templateId) {
        setState(() => _panelError = '$e');
      }
    }
  }

  /// Placeholder-fill preview document assembled LOCALLY from the template
  /// JSON — typed FormSection/FormBlock input for the FormView package, so
  /// no style information is lost to an intermediate render format.
  FormDocument _assemblePreview(Map<String, dynamic> tpl) {
    final fields =
        (((tpl['schema'] as Map?)?['fields'] as List?) ?? const []).cast<Map>();
    final sections =
        ((tpl['defaultSections'] as List?) ?? const [])
            .cast<Map>()
            .map((m) => FormSection.fromJson(m.cast<String, dynamic>()))
            .toList();
    return FormDocument(
      documentId: 'preview',
      templateId: '${tpl['templateId']}',
      templateVersion: '${tpl['version']}',
      metadata: FormDocumentMetadata(
        author: 'preview',
        createdAt: DateTime.now(),
      ),
      sections: sections,
      data: <String, dynamic>{
        for (final f in fields) (f['name'] as String): '《${f['name']}》',
      },
    );
  }

  /// Re-render when the selected template's CURRENT version changed under
  /// us (a conversational edit landed). Cheap: one get_template + version
  /// compare.
  Future<void> _checkVersion() async {
    final id = _selectedId;
    final current = _tpl?['version'];
    if (id == null || current == null) return;
    if (_dirty) return; // don't clobber pending inspector edits
    try {
      final out = await callFormTool(widget.server, 'form.get_template', {
        'templateId': id,
      });
      final v = (out['template'] as Map?)?['version'];
      if (v != null && v != current && mounted && _selectedId == id) {
        await _loadPanel(id);
        _refresh(); // list version badge too
      }
    } catch (_) {
      /* transient — next tick retries */
    }
  }

  // --- actions ---------------------------------------------------------------

  /// Visual creation: name in, template out — a starter skeleton (title
  /// heading + one field) saves immediately; refinement happens in the
  /// inspector or by chat. JSON stays the expert path (Edit JSON).
  Future<void> _createTemplate() async {
    final result = await showScopedDialog<(String, String)>(
      builder: (ctx) => const _NewTemplateDialog(),
    );
    if (result == null) return;
    final (name, idRaw) = result;
    final id = idRaw.trim().isEmpty ? _slug(name) : idRaw.trim();
    try {
      final skeleton =
          jsonDecode(_newTemplateSkeleton()) as Map<String, dynamic>;
      skeleton['templateId'] = id;
      skeleton['name'] = name;
      // NO section title: renderers print it as an extra standalone
      // header above the document (duplicating the title heading block).
      // Section titles are for multi-section documents only.
      await callFormTool(widget.server, 'form.save_template', {
        'template': skeleton,
      });
      _refresh();
      await _select(id);
    } catch (e) {
      await _showError(e);
    }
  }

  static String _slug(String name) {
    final s = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\uAC00-\uD7A3]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp('^-|-\u0024'), '');
    return s.isEmpty ? 'template' : s;
  }

  Future<void> _editor({String? templateId, String? version}) async {
    String initial = _newTemplateSkeleton();
    if (templateId != null) {
      try {
        final out = await callFormTool(widget.server, 'form.get_template', {
          'templateId': templateId,
          if (version != null) 'version': version,
        });
        initial = _pretty.convert(out['template']);
      } catch (e) {
        await _showError(e);
        return;
      }
    }
    if (!mounted) return;
    final saved = await showScopedDialog<bool>(
      builder:
          (ctx) => _TemplateEditorDialog(
            server: widget.server,
            initialJson: initial,
            title:
                templateId == null
                    ? 'New template'
                    : 'Edit $templateId (save = new version)',
          ),
    );
    if (saved == true) {
      _refresh();
      if (_selectedId != null) await _loadPanel(_selectedId!);
    }
  }

  Future<void> _versions(String templateId) async {
    try {
      final out = await callFormTool(
        widget.server,
        'form.get_template_versions',
        {'templateId': templateId},
      );
      if (!mounted) return;
      final versions =
          ((out['versions'] as List?) ?? const [])
              .cast<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList();
      await showScopedDialog<void>(
        builder:
            (ctx) => SimpleDialog(
              title: Text('$templateId versions'),
              children: [
                for (final v in versions)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _editor(
                        templateId: templateId,
                        version: v['version'] as String?,
                      );
                    },
                    child: Text('${v['version']}  ·  ${v['createdAt'] ?? ''}'),
                  ),
              ],
            ),
      );
    } catch (e) {
      await _showError(e);
    }
  }

  Future<void> _delete(String templateId) async {
    final confirmed = await showScopedDialog<bool>(
      builder:
          (ctx) => AlertDialog(
            title: Text('Delete $templateId?'),
            content: const Text(
              'Removes the template and its version history from this project. '
              'Issued documents keep their frozen content and artifacts.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await callFormTool(widget.server, 'form.delete_template', {
        'templateId': templateId,
      });
      if (_selectedId == templateId) {
        setState(() {
          _selectedId = null;
          _tpl = null;
          _previewDoc = null;
          _inspected = null;
        });
      }
      _refresh();
    } catch (e) {
      await _showError(e);
    }
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 300, child: _masterList(context)),
        const VerticalDivider(width: 1),
        Expanded(child: _panel(context)),
      ],
    );
  }

  Widget _masterList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Text('Templates', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              inspectTag(
                type: 'button',
                id: 'fb.templates.reload',
                child: IconButton(
                  tooltip: 'Reload',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ),
              inspectTag(
                type: 'button',
                id: 'fb.templates.new',
                child: IconButton(
                  tooltip: 'New template',
                  onPressed: _createTemplate,
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'name · id…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _templates,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('${snap.error}'));
              }
              final loaded = snap.data;
              if (loaded == null) {
                return const Center(child: CircularProgressIndicator());
              }
              var items = loaded;
              final q = _search.text.trim().toLowerCase();
              if (q.isNotEmpty) {
                items = [
                  for (final t in items)
                    if ('${t['name']} ${t['templateId']}'
                        .toLowerCase()
                        .contains(q))
                      t,
                ];
              }
              if (items.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No templates — create one, or ask the manager in '
                      'chat to author one.',
                    ),
                  ),
                );
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final t = items[i];
                  final id = t['templateId'] as String;
                  return ListTile(
                    dense: true,
                    selected: id == _selectedId,
                    leading: const Icon(Icons.description_outlined, size: 18),
                    title: Text(
                      '${t['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('$id · v${t['version']}'),
                    onTap: () => _select(id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _panel(BuildContext context) {
    final theme = Theme.of(context);
    final tpl = _tpl;
    if (_selectedId == null) {
      return const Center(
        child: Text(
          'Select a template — the form shows here.\n'
          'Edit it by chat while watching ("put a navy outline on the '
          'title…"); the view follows each saved version.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final pageSize =
        ((tpl?['layoutPolicy'] as Map?)?['pageSize'] as Map?)
            ?.cast<String, dynamic>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tpl == null
                      ? _selectedId!
                      : '${tpl['name']}  ·  ${tpl['templateId']} '
                          'v${tpl['version']}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_dirty) ...[
                inspectTag(
                  type: 'button',
                  id: 'fb.tpl.saveVersion',
                  child: FilledButton.icon(
                    onPressed: _saveEditedVersion,
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: Text(
                      'Save v${_bumpPatch('${_tpl?['version'] ?? '0.0.0'}')}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('Form')),
                  ButtonSegment(value: 1, label: Text('Fields')),
                  ButtonSegment(value: 2, label: Text('Structure')),
                ],
                selected: {_panelTab},
                onSelectionChanged: (s) => setState(() => _panelTab = s.first),
              ),
              const SizedBox(width: 8),
              inspectTag(
                type: 'button',
                id: 'fb.tpl.metrics',
                child: IconButton(
                  tooltip: 'Metrics (mm rulers)',
                  isSelected: _metrics,
                  onPressed: () => setState(() => _metrics = !_metrics),
                  icon: const Icon(Icons.straighten, size: 18),
                ),
              ),
              inspectTag(
                type: 'button',
                id: 'fb.tpl.addBlock',
                child: IconButton(
                  tooltip: 'Add block',
                  onPressed: _addBlock,
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                ),
              ),
              inspectTag(
                type: 'button',
                id: 'fb.tpl.versions',
                child: IconButton(
                  tooltip: 'Version history',
                  onPressed: () => _versions(_selectedId!),
                  icon: const Icon(Icons.history, size: 18),
                ),
              ),
              inspectTag(
                type: 'button',
                id: 'fb.tpl.editJson',
                child: IconButton(
                  tooltip: 'Edit JSON',
                  onPressed: () => _editor(templateId: _selectedId),
                  icon: const Icon(Icons.data_object, size: 18),
                ),
              ),
              inspectTag(
                type: 'button',
                id: 'fb.tpl.delete',
                child: IconButton(
                  tooltip: 'Delete',
                  onPressed: () => _delete(_selectedId!),
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_panelTab) {
            1 => _fieldsTab(theme),
            2 => _structureTab(theme),
            _ =>
              _previewDoc != null
                  ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: FormView(
                          document: _previewDoc!,
                          imageBaseDir: widget.projectRoot,
                          pageWidthMm:
                              (pageSize?['width'] as num?)?.toDouble() ?? 210,
                          pageHeightMm:
                              (pageSize?['height'] as num?)?.toDouble() ?? 297,
                          showMetrics: _metrics,
                          pageBorder:
                              ((_tpl?['layoutPolicy'] as Map?)?['pageBorder']
                                      as Map?)
                                  ?.cast<String, dynamic>(),
                          selectedBlockId: _inspected?.block.blockId,
                          onBlockTap: (ref) => setState(() => _inspected = ref),
                        ),
                      ),
                      if (_inspected != null) _inspector(theme),
                    ],
                  )
                  : Center(
                    child:
                        _panelError != null
                            ? Text('Preview failed: $_panelError')
                            : const CircularProgressIndicator(),
                  ),
          },
        ),
      ],
    );
  }

  /// Tap-to-EDIT — the App Builder properties-panel idiom, editable:
  /// text/number fields, toggles, alignment segments and hex+swatch colour
  /// rows write into the template JSON, the sheet re-renders live, and
  /// "Save vNEXT" persists a new version (patch bump).
  Widget _inspector(ThemeData theme) {
    final blockId = _inspected!.block.blockId;
    final json = _blockJsonOf(blockId);
    if (json == null) return const SizedBox.shrink();
    return _BlockInspector(
      key: ValueKey('inspect::$_selectedId::$blockId::${_tpl?['version']}'),
      blockJson: json,
      onMutate: (mutate) => _mutateBlock(blockId, mutate),
      onClose: () => setState(() => _inspected = null),
      onDelete: () => _deleteBlock(blockId),
    );
  }

  /// The LIVE template-JSON map for a block (the inspector edits this).
  Map<String, dynamic>? _blockJsonOf(String blockId) {
    for (final sec
        in ((_tpl?['defaultSections'] as List?) ?? const []).cast<Map>()) {
      for (final b in ((sec['blocks'] as List?) ?? const []).cast<Map>()) {
        if ('${b['blockId']}' == blockId) return b.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// Apply an in-place block edit, re-render the sheet, arm "Save vNEXT".
  void _mutateBlock(String blockId, void Function(Map<String, dynamic>) fn) {
    final json = _blockJsonOf(blockId);
    if (json == null) return;
    setState(() {
      fn(json);
      _dirty = true;
      _previewDoc = _assemblePreview(_tpl!);
    });
  }

  /// Add a block to the first section (visual creation — LLM/chat can do
  /// richer surgery; this covers the common "one more line/field/image").
  Future<void> _addBlock() async {
    if (_tpl == null) return;
    final type = await showScopedDialog<String>(
      builder:
          (ctx) => SimpleDialog(
            title: const Text('Add block'),
            children: [
              for (final (t, label, icon) in [
                ('heading', 'Heading', Icons.title),
                ('text', 'Text', Icons.notes),
                ('formField', 'Field', Icons.input),
                ('table', 'Table', Icons.table_chart_outlined),
                ('image', 'Image (logo / seal)', Icons.image_outlined),
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(t),
                  child: Row(
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 8),
                      Text(label),
                    ],
                  ),
                ),
            ],
          ),
    );
    if (type == null) return;
    setState(() {
      final sections = ((_tpl!['defaultSections'] as List?) ?? []).cast<Map>();
      if (sections.isEmpty) {
        _tpl!['defaultSections'] = [
          <String, dynamic>{
            'sectionId': 'main',
            'index': 0,
            'blocks': <Map<String, dynamic>>[],
          },
        ];
      }
      final blocks =
          ((_tpl!['defaultSections'] as List).first['blocks'] as List)
              .cast<Map>();
      final id = 'b${DateTime.now().millisecondsSinceEpoch % 100000}';
      blocks.add(switch (type) {
        'heading' => <String, dynamic>{
          'blockId': id,
          'type': 'heading',
          'index': blocks.length,
          'level': 2,
          'content': 'Heading',
        },
        'text' => <String, dynamic>{
          'blockId': id,
          'type': 'text',
          'index': blocks.length,
          'content': 'Text',
        },
        'formField' => <String, dynamic>{
          'blockId': id,
          'type': 'formField',
          'index': blocks.length,
          'fieldName': 'field',
          'fieldType': 'text',
        },
        'table' => <String, dynamic>{
          'blockId': id,
          'type': 'table',
          'index': blocks.length,
          'columns': [
            {'id': 'c1', 'title': 'Column 1', 'type': 'string'},
            {'id': 'c2', 'title': 'Column 2', 'type': 'string'},
          ],
          'rows': [],
        },
        _ => <String, dynamic>{
          'blockId': id,
          'type': 'image',
          'index': blocks.length,
          'src': 'image.png',
          'maxWidth': 120,
        },
      });
      _dirty = true;
      _previewDoc = _assemblePreview(_tpl!);
    });
  }

  /// Remove a block from the template (inspector action).
  void _deleteBlock(String blockId) {
    setState(() {
      for (final sec
          in ((_tpl?['defaultSections'] as List?) ?? const []).cast<Map>()) {
        ((sec['blocks'] as List?) ?? const []).removeWhere(
          (b) => '${(b as Map)['blockId']}' == blockId,
        );
      }
      _inspected = null;
      _dirty = true;
      _previewDoc = _assemblePreview(_tpl!);
    });
  }

  /// Persist the edited template as a NEW VERSION (semver patch bump) —
  /// the same rule the conversational editor follows.
  Future<void> _saveEditedVersion() async {
    final tpl = _tpl;
    if (tpl == null) return;
    try {
      tpl['version'] = _bumpPatch('${tpl['version']}');
      await callFormTool(widget.server, 'form.save_template', {
        'template': tpl,
      });
      _dirty = false;
      _refresh();
      await _loadPanel(_selectedId!);
    } catch (e) {
      await _showError(e);
    }
  }

  static String _bumpPatch(String version) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
    if (m == null) return '$version.1';
    return '${m[1]}.${m[2]}.${int.parse(m[3]!) + 1}';
  }

  Widget _fieldsTab(ThemeData theme) {
    final fields =
        (((_tpl?['schema'] as Map?)?['fields'] as List?) ?? const [])
            .cast<Map>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: DataTable(
        columns: const [
          DataColumn(label: Text('field')),
          DataColumn(label: Text('type')),
        ],
        rows: [
          for (final f in fields)
            DataRow(
              cells: [
                DataCell(Text('${f['name']}')),
                DataCell(Text('${f['type'] ?? ''}')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _structureTab(ThemeData theme) {
    final sections =
        ((_tpl?['defaultSections'] as List?) ?? const []).cast<Map>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final sec in sections) ...[
            Text(
              '§ ${sec['title'] ?? sec['sectionId']}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final b in ((sec['blocks'] as List?) ?? const []).cast<Map>())
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 2),
                child: Text(
                  '• ${b['type']}'
                  '${b['fieldName'] != null ? ' → ${b['fieldName']}' : ''}'
                  '${b['content'] != null ? ' — "${b['content']}"' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (sections.isEmpty)
            const Text(
              'No defaultSections — this template renders an EMPTY body. '
              'Add blocks so field values appear.',
            ),
        ],
      ),
    );
  }
}

class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({
    required this.server,
    required this.initialJson,
    required this.title,
  });

  final BuiltinToolRegistry server;
  final String initialJson;
  final String title;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialJson,
  );
  String? _error;
  bool _saving = false;

  Future<void> _save() async {
    Object? decoded;
    try {
      decoded = jsonDecode(_controller.text);
    } catch (e) {
      setState(() => _error = 'Invalid JSON: $e');
      return;
    }
    if (decoded is! Map) {
      setState(() => _error = 'Template must be a JSON object');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final template = decoded.cast<String, dynamic>();
      try {
        await callFormTool(widget.server, 'form.save_template', {
          'template': template,
        });
      } catch (e) {
        // Same (templateId, version) is rejected by design — plain
        // re-saves auto-bump the patch slot instead of dead-ending.
        if ('$e'.contains('already exists')) {
          template['version'] = _TemplatesPageState._bumpPatch(
            '${template['version']}',
          );
          await callFormTool(widget.server, 'form.save_template', {
            'template': template,
          });
        } else {
          rethrow;
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 640,
        height: 460,
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save version'),
        ),
      ],
    );
  }
}

/// Editable block properties — App Builder panel idiom (30px rows, mono
/// labels, 14px swatches) with EDITORS: text/number fields, mark toggles,
/// alignment segments, hex colours. Every change mutates the template
/// JSON through [onMutate]; the page re-renders the sheet and arms the
/// "Save vNEXT" button.
class _BlockInspector extends StatefulWidget {
  const _BlockInspector({
    super.key,
    required this.blockJson,
    required this.onMutate,
    required this.onClose,
    required this.onDelete,
  });

  final Map<String, dynamic> blockJson;
  final void Function(void Function(Map<String, dynamic> block)) onMutate;
  final VoidCallback onClose;
  final VoidCallback onDelete;

  @override
  State<_BlockInspector> createState() => _BlockInspectorState();
}

class _BlockInspectorState extends State<_BlockInspector> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, String> _lastPushed = {};

  /// Controller factory with a WRITE LISTENER — edits reach the template
  /// JSON whether they come from human keystrokes or a programmatic
  /// `studio.ui.type` (which bypasses onChanged).
  TextEditingController _ctrl(
    String key,
    String initial,
    void Function(String) push,
  ) {
    return _ctrls.putIfAbsent(key, () {
      final c = TextEditingController(text: initial);
      _lastPushed[key] = initial;
      c.addListener(() {
        if (_lastPushed[key] == c.text) return;
        _lastPushed[key] = c.text;
        push(c.text);
      });
      return c;
    });
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _b => widget.blockJson;
  Map<String, dynamic> get _style =>
      (_b['style'] as Map?)?.cast<String, dynamic>() ?? const {};

  void _setTop(String key, Object? value) {
    widget.onMutate((b) {
      if (value == null || value == '') {
        b.remove(key);
      } else {
        b[key] = value;
      }
    });
  }

  void _setStyle(String key, Object? value) {
    widget.onMutate((b) {
      final style =
          ((b['style'] as Map?)?.cast<String, dynamic>()) ??
          <String, dynamic>{};
      if (value == null || value == '') {
        style.remove(key);
      } else {
        style[key] = value;
      }
      if (style.isEmpty) {
        b.remove('style');
      } else {
        b['style'] = style;
      }
    });
  }

  void _setBorder(String key, Object? value) {
    widget.onMutate((b) {
      final style =
          ((b['style'] as Map?)?.cast<String, dynamic>()) ??
          <String, dynamic>{};
      final border =
          ((style['border'] as Map?)?.cast<String, dynamic>()) ??
          <String, dynamic>{};
      if (value == null || value == '') {
        border.remove(key);
      } else {
        border[key] = value;
      }
      if (border.isEmpty) {
        style.remove('border');
      } else {
        style['border'] = border;
      }
      b['style'] = style;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = VibeTokens.colorOf(context);
    final type = '${_b['type']}';
    final border = (_style['border'] as Map?)?.cast<String, dynamic>();
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
            child: Row(
              children: [
                Icon(_icon(type), size: 16, color: c.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_b['blockId']}',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                  label: Text(
                    type,
                    style: vibeMono(size: 10, color: c.textSecondary),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                if (type == 'heading' || type == 'text') ...[
                  _header('CONTENT', c),
                  _textRow(
                    'content',
                    '${_b['content'] ?? ''}',
                    (v) => _setTop('content', v),
                  ),
                  if (type == 'heading')
                    _numRow(
                      'level',
                      '${_b['level'] ?? 1}',
                      (v) => _setTop('level', v?.toInt()),
                    ),
                ],
                if (type == 'formField') ...[
                  _header('FIELD', c),
                  _textRow(
                    'fieldName',
                    '${_b['fieldName'] ?? ''}',
                    (v) => _setTop('fieldName', v),
                  ),
                  _textRow(
                    'fieldType',
                    '${_b['fieldType'] ?? 'text'}',
                    (v) => _setTop('fieldType', v),
                  ),
                ],
                if (type == 'image') ...[
                  _header('IMAGE', c),
                  _textRow(
                    'src',
                    '${_b['src'] ?? ''}',
                    (v) => _setTop('src', v),
                  ),
                  _textRow(
                    'alt',
                    '${_b['alt'] ?? ''}',
                    (v) => _setTop('alt', v),
                  ),
                  _numRow(
                    'maxWidth',
                    '${_b['maxWidth'] ?? ''}',
                    (v) => _setTop('maxWidth', v),
                  ),
                ],
                _header('STYLE', c),
                _alignRow(),
                _numRow(
                  'fontSize',
                  '${_style['fontSize'] ?? _style['size'] ?? ''}',
                  (v) => _setStyle('fontSize', v),
                ),
                _marksRow(c),
                _colorRow('color', (v) => _setStyle('color', v)),
                _colorRow('background', (v) => _setStyle('background', v)),
                _colorRow('highlight', (v) => _setStyle('highlight', v)),
                _header('BORDER', c),
                _colorRow(
                  'border.color',
                  (v) => _setBorder('color', v),
                  value: '${border?['color'] ?? ''}',
                ),
                _numRow(
                  'border.width',
                  '${border?['width'] ?? ''}',
                  (v) => _setBorder('width', v),
                ),
                _numRow(
                  'border.radius',
                  '${border?['radius'] ?? ''}',
                  (v) => _setBorder('radius', v),
                ),
                _header('BOX', c),
                _numRow(
                  'height',
                  '${_style['height'] ?? ''}',
                  (v) => _setStyle('height', v),
                ),
                _header('PLACEMENT', c),
                _placementRows(c),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: OutlinedButton.icon(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete block'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Edits re-render the sheet; press "Save vNEXT" above to '
              'persist a new template version. Chat works too — name this '
              'block ("${_b['blockId']}").',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  // --- rows -----------------------------------------------------------------

  Widget _header(String title, dynamic c) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
    child: Text(
      title,
      style: vibeMono(
        size: 10,
        color: c.textSecondary,
      ).copyWith(letterSpacing: 1.1),
    ),
  );

  Widget _labeled(String label, Widget editor) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: vibeMono(size: 12, color: c.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: editor),
        ],
      ),
    );
  }

  Widget _textRow(String label, String value, void Function(String?) set) {
    return _labeled(
      label,
      TextField(
        controller: _ctrl(label, value, (v) => set(v.isEmpty ? null : v)),
        style: vibeMono(size: 12),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      ),
    );
  }

  Widget _numRow(String label, String value, void Function(num?) set) {
    return _labeled(
      label,
      TextField(
        controller: _ctrl(
          label,
          value == 'null' ? '' : value,
          (v) => set(num.tryParse(v)),
        ),
        keyboardType: TextInputType.number,
        style: vibeMono(size: 12),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
      ),
    );
  }

  Widget _alignRow() {
    final current = _style['align'] as String?;
    // align positions a block WITHIN the flow; a placed block left the
    // flow (placement anchors it on the page), so align has no effect —
    // grey it out instead of showing two competing position controls.
    if (_style['placement'] != null) {
      final c = VibeTokens.colorOf(context);
      return _labeled(
        'align',
        Text(
          '— placed (see PLACEMENT)',
          style: vibeMono(size: 11, color: c.textSecondary),
        ),
      );
    }
    return _labeled(
      'align',
      SegmentedButton<String>(
        showSelectedIcon: false,
        emptySelectionAllowed: true,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment(
            value: 'left',
            icon: Icon(Icons.format_align_left, size: 14),
          ),
          ButtonSegment(
            value: 'center',
            icon: Icon(Icons.format_align_center, size: 14),
          ),
          ButtonSegment(
            value: 'right',
            icon: Icon(Icons.format_align_right, size: 14),
          ),
        ],
        selected: {if (current != null) current},
        onSelectionChanged:
            (sel) => _setStyle('align', sel.isEmpty ? null : sel.first),
      ),
    );
  }

  Widget _marksRow(dynamic c) {
    Widget chip(String key, String label) {
      final on = _style[key] == true;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          visualDensity: VisualDensity.compact,
          label: Text(label, style: vibeMono(size: 11)),
          selected: on,
          onSelected: (v) => _setStyle(key, v ? true : null),
        ),
      );
    }

    return _labeled(
      'marks',
      Wrap(
        children: [
          chip('bold', 'B'),
          chip('italic', 'I'),
          chip('underline', 'U'),
        ],
      ),
    );
  }

  Widget _colorRow(String label, void Function(String?) set, {String? value}) {
    final key = label.contains('.') ? label.split('.').last : label;
    final raw = value ?? '${_style[key] ?? ''}';
    final hex = raw == 'null' ? '' : raw;
    final h = hex.replaceFirst('#', '');
    final parsed = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
    final c = VibeTokens.colorOf(context);
    return _labeled(
      label,
      Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: parsed != null ? Color(parsed) : null,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: c.borderStrong, width: 0.5),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _ctrl(label, hex, (v) => set(v.isEmpty ? null : v)),
              style: vibeMono(size: 12),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '#RRGGBB',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// PLACEMENT — free positioning on the page: anchor + mm offsets.
  /// Empty anchor = in the flow. The seal use-case: bottom-left, x:20 y:20.
  Widget _placementRows(dynamic c) {
    final pl = (_style['placement'] as Map?)?.cast<String, dynamic>();
    void setPl(String key, Object? value) {
      widget.onMutate((b) {
        final style =
            ((b['style'] as Map?)?.cast<String, dynamic>()) ??
            <String, dynamic>{};
        final placement =
            ((style['placement'] as Map?)?.cast<String, dynamic>()) ??
            <String, dynamic>{};
        if (value == null) {
          placement.remove(key);
        } else {
          placement[key] = value;
        }
        if (placement['anchor'] == null) {
          style.remove('placement');
        } else {
          style['placement'] = placement;
        }
        if (style.isEmpty) {
          b.remove('style');
        } else {
          b['style'] = style;
        }
      });
    }

    final anchors = <String?>[null, ...kPlacementAnchors];
    // Out-of-spec anchors are NOT adopted into the dropdown (save is
    // rejected by the form.save_template vocabulary gate anyway) — show
    // an error banner naming the bad value + the allowed list, and keep
    // the dropdown crash-safe by selecting nothing.
    final current = pl?['anchor'] as String?;
    final offSpec = current != null && !anchors.contains(current);
    return Column(
      children: [
        if (offSpec)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Text(
              "anchor '$current' is not in the spec — pick one of: "
              '${kPlacementAnchors.join(', ')}. Saving is rejected until '
              'fixed.',
              style: vibeMono(size: 11, color: const Color(0xFFE57373)),
            ),
          ),
        _labeled(
          'anchor',
          DropdownButton<String?>(
            value: offSpec ? null : current,
            isExpanded: true,
            isDense: true,
            style: vibeMono(size: 12),
            hint:
                offSpec ? Text("'$current'?", style: vibeMono(size: 12)) : null,
            items: [
              for (final a in anchors)
                DropdownMenuItem(value: a, child: Text(a ?? 'in flow')),
            ],
            onChanged: (v) {
              setPl('anchor', v);
              // Re-apply what the panel SHOWS: after a round-trip through
              // "in flow" the x/y/width controllers still display the old
              // values while the JSON lost them — silently diverging
              // (display ≠ template). Round-trips must keep them in sync.
              if (v != null) {
                for (final (key, ctrlKey) in [
                  ('x', 'x (mm)'),
                  ('y', 'y (mm)'),
                  ('width', 'width (mm)'),
                ]) {
                  final n = num.tryParse(_ctrls[ctrlKey]?.text ?? '');
                  if (n != null) setPl(key, n);
                }
              }
            },
          ),
        ),
        if (pl != null) ...[
          _numRow('x (mm)', '${pl['x'] ?? ''}', (v) => setPl('x', v)),
          _numRow('y (mm)', '${pl['y'] ?? ''}', (v) => setPl('y', v)),
          _numRow(
            'width (mm)',
            '${pl['width'] ?? ''}',
            (v) => setPl('width', v),
          ),
        ],
      ],
    );
  }

  IconData _icon(String type) => switch (type) {
    'heading' => Icons.title,
    'text' => Icons.notes,
    'formField' => Icons.input,
    'table' => Icons.table_chart_outlined,
    'image' => Icons.image_outlined,
    _ => Icons.widgets_outlined,
  };
}

/// Name → templateId (auto-slug) creation dialog. LISTENER-based (not
/// onChanged) so programmatic writes into the controllers — `studio.ui.type`
/// drivers, tests — enable the Create button exactly like human typing.
class _NewTemplateDialog extends StatefulWidget {
  const _NewTemplateDialog();

  @override
  State<_NewTemplateDialog> createState() => _NewTemplateDialogState();
}

class _NewTemplateDialogState extends State<_NewTemplateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _id = TextEditingController();
  bool _idTouched = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      if (!_idTouched) {
        final slug = _TemplatesPageState._slug(_name.text);
        if (_id.text != slug) _id.text = slug;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New template'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name (e.g. 견적서)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _id,
              decoration: const InputDecoration(
                labelText: 'templateId',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _idTouched = true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _name.text.trim().isEmpty
                  ? null
                  : () =>
                      Navigator.of(context).pop((_name.text.trim(), _id.text)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
