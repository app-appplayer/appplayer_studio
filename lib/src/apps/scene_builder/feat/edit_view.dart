import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge, inspectTag;
import 'package:appplayer_studio/ui.dart';

/// Scenario step editor.
///
/// * `scenarioId == null` → blank-create flow (id input + skeleton).
/// * `scenarioId` set → reads via `studio.scenario.read`, surfaces a
///   read-only step list plus an editable JSON pane that saves
///   through `studio.builder.writeScenario`.
class EditView extends StatefulWidget {
  const EditView({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
    this.scenarioId,
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;
  final String? scenarioId;

  @override
  State<EditView> createState() => _EditViewState();
}

class _EditViewState extends State<EditView> {
  Map<String, dynamic>? _scenario;
  String? _source;
  String? _path;
  bool _loading = false;
  String? _error;
  bool _showJson = false;
  String? _loadedId;
  final TextEditingController _jsonCtrl = TextEditingController();
  final TextEditingController _newIdCtrl = TextEditingController();
  bool _dirty = false;
  bool _saving = false;
  String? _resolvedMbdPath;

  @override
  void initState() {
    super.initState();
    _resolveMbdPath();
    if (widget.scenarioId != null) _load(widget.scenarioId!);
  }

  @override
  void didUpdateWidget(covariant EditView old) {
    super.didUpdateWidget(old);
    if (widget.scenarioId != null && widget.scenarioId != _loadedId) {
      _load(widget.scenarioId!);
    } else if (widget.scenarioId == null && _loadedId != null) {
      // Reset to blank-create mode.
      setState(() {
        _scenario = null;
        _source = null;
        _path = null;
        _showJson = false;
        _loadedId = null;
        _jsonCtrl.clear();
        _newIdCtrl.clear();
        _dirty = false;
      });
    }
  }

  @override
  void dispose() {
    _jsonCtrl.dispose();
    _newIdCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, dynamic> params,
  ) async {
    final fn = widget.chromeBridge.callHostTool;
    if (fn == null) {
      return <String, dynamic>{'ok': false, 'error': 'chrome bridge not wired'};
    }
    return fn(tool, params);
  }

  Map<String, dynamic>? _unwrap(Map<String, dynamic> result) {
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map && first['text'] is String) {
        try {
          final decoded = jsonDecode(first['text'] as String);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          /* fall through */
        }
      }
    }
    return null;
  }

  Future<void> _resolveMbdPath() async {
    final result = await _call('studio.bundle.list', const <String, dynamic>{});
    if (!mounted) return;
    final body = _unwrap(result) ?? result;
    final bundles = body['bundles'];
    if (bundles is! List) return;
    String? mbd;
    for (final b in bundles) {
      if (b is Map && b['namespace'] == 'scene_builder' && b['name'] != null) {
        mbd = b['mbdPath']?.toString();
        break;
      }
    }
    if (mbd == null) {
      for (final b in bundles) {
        if (b is Map && b['namespace'] == 'scene_builder') {
          mbd = b['mbdPath']?.toString();
          break;
        }
      }
    }
    setState(() => _resolvedMbdPath = mbd);
  }

  Future<void> _load(String id) async {
    setState(() {
      _loading = true;
      _error = null;
      _loadedId = id;
    });
    final result = await _call('studio.scenario.read', <String, dynamic>{
      'id': id,
    });
    if (!mounted) return;
    if (result['ok'] == false) {
      setState(() {
        _loading = false;
        _error = result['error']?.toString() ?? 'failed';
        _scenario = null;
      });
      return;
    }
    final body = _unwrap(result) ?? result;
    final scenario = body['scenario'] as Map<String, dynamic>?;
    setState(() {
      _loading = false;
      _scenario = scenario;
      _source = body['source']?.toString();
      _path = body['path']?.toString();
      _jsonCtrl.text =
          scenario == null
              ? ''
              : const JsonEncoder.withIndent('  ').convert(scenario);
      _dirty = false;
    });
  }

  Future<void> _save() async {
    if (_resolvedMbdPath == null) {
      _snack('mbdPath not resolved yet');
      return;
    }
    Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(_jsonCtrl.text);
      if (decoded is! Map<String, dynamic>) {
        _snack('scenario must be a JSON object');
        return;
      }
      parsed = decoded;
    } catch (e) {
      _snack('JSON parse: $e');
      return;
    }
    final id = parsed['id'];
    if (id is! String || id.isEmpty) {
      _snack('scenario.id required (string)');
      return;
    }
    setState(() => _saving = true);
    final result = await _call(
      'studio.builder.writeScenario',
      <String, dynamic>{'mbdPath': _resolvedMbdPath, 'scenario': parsed},
    );
    if (!mounted) return;
    setState(() => _saving = false);
    final body = _unwrap(result) ?? result;
    if (body['ok'] == false) {
      _snack('Save failed · ${body['error'] ?? 'unknown'}');
      return;
    }
    setState(() {
      _scenario = parsed;
      _loadedId = id;
      _dirty = false;
    });
    _snack('Saved · $id');
  }

  Future<void> _createBlank() async {
    final id = _newIdCtrl.text.trim();
    if (id.isEmpty) {
      _snack('Enter an id first');
      return;
    }
    final skeleton = <String, dynamic>{
      'id': id,
      'title': id,
      'description': '',
      'fps': 24,
      'record': true,
      'recordingLabel': id,
      'encodeAfter': true,
      'overlayTracks': <dynamic>[],
      'steps': <dynamic>[
        <String, dynamic>{
          'tool': 'studio.renderer.activate',
          'args': <String, dynamic>{'target': 'home'},
          'settleMs': 1000,
        },
      ],
    };
    setState(() {
      _scenario = skeleton;
      _loadedId = id;
      _showJson = true;
      _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(skeleton);
      _dirty = true;
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (widget.scenarioId == null && _scenario == null) {
      return _newScreen(c);
    }
    if (_loading) {
      return _centeredText('Loading…', c.textTertiary);
    }
    if (_error != null) {
      return _centeredText('Failed: $_error', c.coral);
    }
    if (_scenario == null) {
      return _centeredText('No scenario data', c.textTertiary);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(),
        Expanded(child: _showJson ? _jsonPane() : _stepPane()),
      ],
    );
  }

  Widget _newScreen(dynamic c) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(Icons.add_circle_outline, size: 32, color: c.mint),
            const SizedBox(height: VbuTokens.space2),
            Text(
              'Create a new scenario',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: VbuTokens.space1),
            Text(
              'Enter a kebab-case id; the file will be saved as '
              '<id>.json under the scene_builder seed bundle.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: VbuTokens.space3),
            inspectTag(
              type: 'dialog_input',
              id: 'new_scenario_id',
              label: 'id',
              child: TextField(
                controller: _newIdCtrl,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 12,
                  color: c.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'my-scenario-id',
                  hintStyle: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 12,
                    color: c.textMuted,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.borderDefault),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.borderDefault),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.mint),
                  ),
                ),
                onSubmitted: (_) => _createBlank(),
              ),
            ),
            const SizedBox(height: VbuTokens.space2),
            inspectTag(
              type: 'dialog_action',
              id: 'new_scenario_create',
              label: 'Create blank scenario',
              child: FilledButton(
                onPressed: _createBlank,
                style: FilledButton.styleFrom(
                  backgroundColor: c.mint,
                  foregroundColor: c.bg,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text('Create blank scenario'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final c = VbuTokens.colorOf(context);
    final id = _loadedId ?? '';
    final title = (_scenario?['title'] ?? id).toString();
    final description = _scenario?['description']?.toString() ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space3,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title.isEmpty ? id : title,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
              ),
              if (_dirty) ...<Widget>[
                _toolbarButton(
                  icon: _saving ? Icons.hourglass_top : Icons.save,
                  label: _saving ? 'Saving…' : 'Save',
                  onTap: _saving ? null : _save,
                  tint: c.mint,
                ),
                const SizedBox(width: 6),
              ],
              _toolbarButton(
                icon: _showJson ? Icons.view_list : Icons.code,
                label: _showJson ? 'Steps' : 'JSON',
                onTap: () => setState(() => _showJson = !_showJson),
              ),
            ],
          ),
          if (description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              description,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textSecondary,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              _chip(id),
              const SizedBox(width: 6),
              if (_source != null) _chip(_source!),
              if (_path != null) ...<Widget>[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _path!,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 10,
                      color: c.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepPane() {
    final stepsRaw = _scenario?['steps'];
    final steps = stepsRaw is List ? stepsRaw : const <dynamic>[];
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      itemCount: steps.length + 1, // +1 for trailing Add row
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        if (i == steps.length) return _addStepRow();
        final step = steps[i];
        if (step is! Map) return const SizedBox.shrink();
        return _stepRow(i, step.cast<String, dynamic>());
      },
    );
  }

  void _addStep() {
    setState(() {
      final scenario = _scenario ??= <String, dynamic>{};
      final List steps;
      if (scenario['steps'] is List) {
        steps = scenario['steps'] as List;
      } else {
        final newList = <dynamic>[];
        scenario['steps'] = newList;
        steps = newList;
      }
      steps.add(<String, dynamic>{
        'tool': '',
        'args': <String, dynamic>{},
        'settleMs': 600,
        'label': '',
      });
      _dirty = true;
      _syncJsonFromScenario();
    });
  }

  void _removeStep(int index) {
    setState(() {
      final steps = _scenario?['steps'];
      if (steps is List && index >= 0 && index < steps.length) {
        steps.removeAt(index);
        _dirty = true;
        _syncJsonFromScenario();
      }
    });
  }

  void _syncJsonFromScenario() {
    if (_scenario == null) return;
    _jsonCtrl.text = const JsonEncoder.withIndent('  ').convert(_scenario);
  }

  Widget _addStepRow() {
    final c = VbuTokens.colorOf(context);
    return inspectTag(
      type: 'tool',
      id: 'step_add',
      label: 'Add step',
      child: OutlinedButton.icon(
        onPressed: _addStep,
        icon: const Icon(Icons.add, size: 14),
        label: const Text('Add step'),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderDefault),
          padding: const EdgeInsets.symmetric(
            horizontal: VbuTokens.space3,
            vertical: VbuTokens.space2,
          ),
        ),
      ),
    );
  }

  Widget _stepRow(int index, Map<String, dynamic> step) {
    final c = VbuTokens.colorOf(context);
    final toolRaw = step['tool']?.toString();
    final tool = (toolRaw == null || toolRaw.isEmpty) ? null : toolRaw;
    final label = step['label']?.toString();
    final settle = step['settleMs'];
    final args = step['args'];
    final overlays = step['overlays'];
    final overlayCount = overlays is List ? overlays.length : 0;
    return Container(
      padding: const EdgeInsets.all(VbuTokens.space2),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderDefault, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 22,
                alignment: Alignment.center,
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label ?? tool ?? '(pause)',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
              ),
              if (settle != null) _chip('${settle}ms'),
              if (overlayCount > 0) ...<Widget>[
                const SizedBox(width: 4),
                _chip('$overlayCount ov'),
              ],
              const SizedBox(width: 4),
              inspectTag(
                type: 'tool',
                id: 'step_remove_$index',
                label: 'Remove step',
                child: IconButton(
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove step',
                  icon: Icon(Icons.close, color: c.textTertiary),
                  onPressed: () => _removeStep(index),
                ),
              ),
            ],
          ),
          if (tool != null && label != null) ...<Widget>[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                tool,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 10,
                  color: c.textTertiary,
                ),
              ),
            ),
          ],
          if (args is Map && args.isNotEmpty) ...<Widget>[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                jsonEncode(args),
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 10,
                  color: c.textMuted,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _jsonPane() {
    final c = VbuTokens.colorOf(context);
    return Container(
      margin: const EdgeInsets.all(VbuTokens.space3),
      padding: const EdgeInsets.all(VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderDefault, width: 1),
      ),
      child: TextField(
        controller: _jsonCtrl,
        maxLines: null,
        expands: true,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textSecondary,
          height: 1.5,
        ),
        decoration: const InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (_) {
          if (!_dirty) setState(() => _dirty = true);
        },
      ),
    );
  }

  Widget _chip(String text) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 10,
          color: c.textTertiary,
        ),
      ),
    );
  }

  Widget _centeredText(String text, Color color) {
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? tint,
  }) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tint ?? c.borderDefault, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: tint ?? c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: tint ?? c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
