/// Per-bundle agent model picker — surfaces the agents declared in the
/// active domain's manifest.json and lets the user pick which catalog
/// model each one runs against. Writes the choice back into the same
/// manifest file (atomic via tmp + rename) so the bundle stays the
/// single source of truth — boot replays the values on next launch
/// through `host_bundle_activation.registerAgent` (which already
/// forwards `agent.model.provider` / `agent.model.model`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import '../chat/model_option.dart';
import '../main/chrome_bridge.dart';
import '../shell/app_theme.dart';

class AgentModelsSection extends StatefulWidget {
  const AgentModelsSection({
    super.key,
    required this.manifestPath,
    required this.modelOptions,
    this.chromeBridge,
  });

  /// Absolute path to the bundle's `manifest.json`. Built-ins point at
  /// `seed/<id>.mbd/manifest.json`; manifest-driven domains point at
  /// `<bundle>.mbd/manifest.json` (whichever holds the agents list).
  final String manifestPath;
  final List<VibeModelOption> modelOptions;
  final ChromeBridge? chromeBridge;

  @override
  State<AgentModelsSection> createState() => _AgentModelsSectionState();
}

class _AgentModelsSectionState extends State<AgentModelsSection> {
  Map<String, dynamic> _manifest = const <String, dynamic>{};
  List<Map<String, dynamic>> _agents = const <Map<String, dynamic>>[];
  // True when the parsed manifest stored agents under the canonical
  // `agents.agents` shape (mcp_bundle 0.3+). False = legacy flat shape
  // (`agents: [...]`). We preserve the original shape on save.
  bool _isCanonicalShape = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AgentModelsSection old) {
    super.didUpdateWidget(old);
    if (old.manifestPath != widget.manifestPath) {
      _load();
    }
  }

  void _load() {
    try {
      final f = File(widget.manifestPath);
      if (!f.existsSync()) {
        setState(() {
          _manifest = <String, dynamic>{};
          _agents = const <Map<String, dynamic>>[];
          _loadError = null;
        });
        return;
      }
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        setState(() {
          _manifest = <String, dynamic>{};
          _agents = const <Map<String, dynamic>>[];
          _loadError = 'manifest.json is not an object';
        });
        return;
      }
      final agentsRaw = raw['agents'];
      List<Map<String, dynamic>> agents;
      bool canonical;
      if (agentsRaw is Map<String, dynamic>) {
        final inner = agentsRaw['agents'];
        agents =
            (inner is List)
                ? inner.whereType<Map<String, dynamic>>().toList()
                : const <Map<String, dynamic>>[];
        canonical = true;
      } else if (agentsRaw is List) {
        agents = agentsRaw.whereType<Map<String, dynamic>>().toList();
        canonical = false;
      } else {
        agents = const <Map<String, dynamic>>[];
        canonical = true;
      }
      setState(() {
        _manifest = raw;
        _agents = agents;
        _isCanonicalShape = canonical;
        _loadError = null;
      });
    } catch (e) {
      setState(() {
        _loadError = e;
        _agents = const <Map<String, dynamic>>[];
      });
    }
  }

  String? _modelOf(Map<String, dynamic> agent) {
    final entry = agent['model'];
    if (entry is Map<String, dynamic>) {
      return entry['model'] as String?;
    }
    return agent['modelId'] as String?;
  }

  String? _providerOfModel(String modelId) {
    for (final m in widget.modelOptions) {
      if (m.id == modelId) return m.provider;
    }
    return null;
  }

  /// Verbose dropdown entry — joins label · provider · note so the
  /// menu mirrors the host's `kStudioModelCatalog` description (e.g.
  /// "Opus 4.7 · anthropic · most capable · highest cost"). Falls back
  /// to just the label when provider / note are absent.
  String _composeModelLabel(VibeModelOption m) {
    final parts = <String>[m.label];
    if (m.provider != null && m.provider!.isNotEmpty) {
      parts.add(m.provider!);
    }
    if (m.note != null && m.note!.isNotEmpty) {
      parts.add(m.note!);
    }
    return parts.join(' · ');
  }

  Future<void> _setAgentModel(int idx, String newModelId) async {
    if (idx < 0 || idx >= _agents.length) return;
    final agent = Map<String, dynamic>.from(_agents[idx]);
    final provider = _providerOfModel(newModelId) ?? 'anthropic';
    final existing = agent['model'];
    if (existing is Map<String, dynamic>) {
      final updated = Map<String, dynamic>.from(existing);
      updated['provider'] = provider;
      updated['model'] = newModelId;
      agent['model'] = updated;
    } else {
      // Either modelId-only or absent — write canonical {provider, model}.
      agent['model'] = <String, dynamic>{
        'provider': provider,
        'model': newModelId,
      };
      // Strip legacy single-string fallback so the canonical entry is
      // the only source on next read.
      agent.remove('modelId');
    }
    final updatedAgents = List<Map<String, dynamic>>.from(_agents)
      ..[idx] = agent;
    final updatedManifest = Map<String, dynamic>.from(_manifest);
    if (_isCanonicalShape) {
      final raw = updatedManifest['agents'];
      final block =
          raw is Map<String, dynamic>
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{};
      block['agents'] = updatedAgents;
      updatedManifest['agents'] = block;
    } else {
      updatedManifest['agents'] = updatedAgents;
    }

    final file = File(widget.manifestPath);
    final tmp = File('${widget.manifestPath}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(updatedManifest),
    );
    await tmp.rename(file.path);

    setState(() {
      _manifest = updatedManifest;
      _agents = updatedAgents;
    });
    widget.chromeBridge?.notify?.call(
      'Saved agent model. Restart to apply.',
      severity: 'info',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (_loadError != null) {
      return Text(
        'Failed to read manifest: $_loadError',
        style: vibeMono(size: 11, color: c.textSecondary),
      );
    }
    if (_agents.isEmpty) {
      return Text(
        'No agents declared in this bundle\'s manifest.',
        style: vibeMono(size: 11, color: c.textTertiary),
      );
    }
    // Cap the rendered height at ~4 rows; below that the list collapses
    // to its natural size (one agent = one row, never an empty 4-row
    // pane). Row height (30px chip + 3px separator) × 4 ≈ 132.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 140),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _agents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 3),
        itemBuilder: (_, i) => _buildRow(i),
      ),
    );
  }

  Widget _buildRow(int i) {
    final agent = _agents[i];
    final id = (agent['id'] as String?) ?? '<agent#$i>';
    final current = _modelOf(agent);
    // Keep the dropdown's value inside the catalog so the menu always
    // renders. When the manifest names a model not in the host catalog
    // (e.g. legacy entry, future model), show the raw id as an option
    // so the user can still see what's persisted.
    final inCatalog = widget.modelOptions.any((m) => m.id == current);
    final value = current ?? widget.modelOptions.first.id;
    return VbuLabelledMenu<String>(
      label: id,
      // 2/3 of the prior 220 width (~147) — keeps long manifest ids
      // legible while leaving more room for the model dropdown.
      labelWidth: 147,
      value: value,
      options: <String>[
        if (!inCatalog && current != null) current,
        for (final m in widget.modelOptions) m.id,
      ],
      labels: <String, String>{
        if (!inCatalog && current != null) current: '$current (not in catalog)',
        for (final m in widget.modelOptions) m.id: _composeModelLabel(m),
      },
      onChanged: (v) => _setAgentModel(i, v),
    );
  }
}
