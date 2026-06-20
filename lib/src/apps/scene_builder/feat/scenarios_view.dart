import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge, inspectTag;
import 'package:appplayer_studio/ui.dart';

/// Scenarios library — list `<configRoot>/scenarios/*.json` via
/// `studio.scenario.list`. Selecting an entry exposes Run / Dry-run /
/// Edit / Delete actions.
class ScenariosView extends StatefulWidget {
  const ScenariosView({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
    this.onEdit,
    this.onNewScenario,
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;
  final void Function(String scenarioId)? onEdit;

  /// Invoked when the user taps the toolbar's New scenario button.
  /// Host wires this to the same code path as the Scene Builder's
  /// header `scene_new` action — Edit mode with a null scenario id,
  /// which surfaces `EditView`'s blank-create form (id input + step
  /// skeleton). Two entry points (toolbar + header) share one flow
  /// so [feedback_studio_button_to_tool_mapping]'s slot-sharing
  /// principle holds.
  final VoidCallback? onNewScenario;

  @override
  State<ScenariosView> createState() => _ScenariosViewState();
}

class _ScenariosViewState extends State<ScenariosView> {
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  String? _selectedId;
  String? _busyAction;

  @override
  void initState() {
    super.initState();
    _refresh();
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

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _call(
      'studio.scenario.list',
      const <String, dynamic>{},
    );
    if (!mounted) return;
    if (result['ok'] == false) {
      setState(() {
        _loading = false;
        _error = result['error']?.toString() ?? 'failed';
        _entries = const <Map<String, dynamic>>[];
      });
      return;
    }
    // Tool wraps the text payload — content[0].text is the JSON we want.
    Map<String, dynamic>? body;
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map && first['text'] is String) {
        try {
          final decoded = jsonDecode(first['text'] as String);
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {
          /* fall through */
        }
      }
    }
    body ??= result;
    final list = body['scenarios'] ?? body['entries'] ?? const <dynamic>[];
    final out = <Map<String, dynamic>>[];
    if (list is List) {
      for (final e in list) {
        if (e is Map<String, dynamic>) out.add(e);
      }
    }
    setState(() {
      _loading = false;
      _entries = out;
    });
  }

  Future<void> _runScenario(String id, {required bool recording}) async {
    setState(() => _busyAction = '$id::${recording ? 'run' : 'dry'}');
    final params = <String, dynamic>{'id': id, if (!recording) 'record': false};
    final result = await _call('studio.scenario.run', params);
    if (!mounted) return;
    setState(() => _busyAction = null);
    final ok = result['ok'] != false;
    final msg =
        ok
            ? (recording ? 'Run finished · $id' : 'Dry-run finished · $id')
            : 'Run failed · ${result['error'] ?? 'unknown'}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[_toolbar(), Expanded(child: _body())],
    );
  }

  Widget _toolbar() {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle, width: 1)),
      ),
      child: Row(
        children: <Widget>[
          inspectTag(
            type: 'tool',
            id: 'scenarios_new',
            label: 'New scenario',
            child: _toolbarButton(
              icon: Icons.add,
              label: 'New scenario',
              onTap: () => widget.onNewScenario?.call(),
            ),
          ),
          const SizedBox(width: VbuTokens.space2),
          _toolbarButton(
            icon: Icons.refresh,
            label: 'Refresh',
            onTap: _refresh,
          ),
          const Spacer(),
          Text(
            '${_entries.length} scenario${_entries.length == 1 ? '' : 's'}',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
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
          border: Border.all(color: c.borderDefault, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: c.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final c = VbuTokens.colorOf(context);
    if (_loading) {
      return Center(
        child: Text(
          'Loading…',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Failed: $_error',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.coral,
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_outlined, size: 32, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space2),
            Text(
              'No scenarios yet',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: VbuTokens.space1),
            Text(
              'Compose one with the Scene Manager or click New scenario.',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: VbuTokens.space2),
      itemBuilder: (_, i) => _row(_entries[i]),
    );
  }

  Widget _row(Map<String, dynamic> entry) {
    final c = VbuTokens.colorOf(context);
    final id = (entry['id'] ?? '').toString();
    final title = (entry['title'] ?? id).toString();
    final path = (entry['path'] ?? '').toString();
    final selected = id == _selectedId;
    return inspectTag(
      type: 'scenario_row',
      id: id,
      title: title,
      extra: <String, dynamic>{'selected': selected, 'path': path},
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedId = selected ? null : id),
        child: Container(
          padding: const EdgeInsets.all(VbuTokens.space3),
          decoration: BoxDecoration(
            color: selected ? c.surface3 : c.surface2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? c.mint : c.borderDefault,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    id,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 10,
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
              if (path.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  path,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: c.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (selected) ...<Widget>[
                const SizedBox(height: VbuTokens.space2),
                Row(
                  children: <Widget>[
                    _rowAction(
                      icon: Icons.play_arrow,
                      label: 'Run & Record',
                      busy: _busyAction == '$id::run',
                      onTap: () => _runScenario(id, recording: true),
                    ),
                    const SizedBox(width: VbuTokens.space2),
                    _rowAction(
                      icon: Icons.fast_forward,
                      label: 'Dry-run',
                      busy: _busyAction == '$id::dry',
                      onTap: () => _runScenario(id, recording: false),
                    ),
                    const SizedBox(width: VbuTokens.space2),
                    _rowAction(
                      icon: Icons.edit,
                      label: 'Edit',
                      onTap: () => widget.onEdit?.call(id),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _rowAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool busy = false,
  }) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.borderDefault, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              busy ? Icons.hourglass_top : icon,
              size: 13,
              color: c.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
