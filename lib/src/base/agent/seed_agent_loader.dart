/// Seed-agent profile loader — every studio host has the same pattern:
/// merge a compiled-in baseline with the agents declared in its seed
/// bundle's `manifest.json`, with seed-supplied entries winning on id
/// collision so the seed remains the single source of truth for studio
/// identity.
///
/// Lifted out of the host so future studios get the same merge + schema
/// tolerance (canonical mcp_bundle shape and legacy flat shape both
/// accepted) for free.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'agent_profile.dart';

/// Read seed-supplied agent profiles from `<seedPath>/manifest.json`
/// and merge them with [baseline].
///
/// Accepts both the canonical mcp_bundle shape `{agents: {agents: []}}`
/// and the legacy flat shape `{agents: []}` so half-migrated seeds keep
/// loading. Seed entries override baseline entries with the same id.
///
/// Returns [baseline] unchanged when [seedPath] is null, the manifest
/// is missing, or the agents list is empty / malformed.
List<VibeAgentProfile> loadSeedAgentProfiles({
  required String? seedPath,
  required List<VibeAgentProfile> baseline,
  String? exposedShortId,
}) {
  final fromSeed = _readSeedAgents(seedPath, exposedShortId: exposedShortId);
  if (fromSeed.isEmpty) return baseline;
  final seedIds = <String>{for (final a in fromSeed) a.id};
  return <VibeAgentProfile>[
    for (final a in baseline)
      if (!seedIds.contains(a.id)) a,
    ...fromSeed,
  ];
}

List<VibeAgentProfile> _readSeedAgents(
  String? seedPath, {
  String? exposedShortId,
}) {
  if (seedPath == null) return const <VibeAgentProfile>[];
  final manifestFile = File(p.join(seedPath, 'manifest.json'));
  if (!manifestFile.existsSync()) return const <VibeAgentProfile>[];
  try {
    final raw = jsonDecode(manifestFile.readAsStringSync());
    if (raw is! Map<String, dynamic>) return const <VibeAgentProfile>[];
    // Accept both canonical mcp_bundle shape {agents: {agents: [...]}}
    // and the legacy flat {agents: [...]} for back-compat.
    final agentsRaw = raw['agents'];
    List? agents;
    if (agentsRaw is Map<String, dynamic>) {
      agents = agentsRaw['agents'] as List?;
    } else if (agentsRaw is List) {
      agents = agentsRaw;
    }
    if (agents == null) return const <VibeAgentProfile>[];
    final out = <VibeAgentProfile>[];
    for (final a in agents) {
      if (a is! Map<String, dynamic>) continue;
      final rawId = a['id'] as String?;
      if (rawId == null || rawId.isEmpty) continue;
      // When [exposedShortId] is given, prefix the manifest id so the
      // baseline-merged catalog mirrors `_activateBundle`'s namespace
      // (`<shortId>.<localId>`). Manifest entries that already carry a
      // dotted prefix (e.g. `ops.admin`) are kept verbatim.
      final id =
          (exposedShortId == null || exposedShortId.isEmpty)
              ? rawId
              : (rawId.contains('.') ? rawId : '$exposedShortId.$rawId');
      // Canonical mcp_bundle agent schema:
      //   id, name, role, systemPrompt, model: {provider, model},
      //   tools[]. Legacy {displayName, modelId, toolNames} also
      //   accepted as fallback so half-migrated seeds keep loading.
      final name =
          (a['name'] as String?) ?? (a['displayName'] as String?) ?? id;
      String modelId;
      String provider;
      final modelEntry = a['model'];
      if (modelEntry is Map<String, dynamic>) {
        modelId =
            (modelEntry['model'] as String?) ??
            (a['modelId'] as String?) ??
            'claude-opus-4-7';
        provider = (modelEntry['provider'] as String?) ?? 'anthropic';
      } else {
        modelId = (a['modelId'] as String?) ?? 'claude-opus-4-7';
        provider = 'anthropic';
      }
      final tools =
          (a['tools'] as List?)?.cast<String>() ??
          (a['toolNames'] as List?)?.cast<String>() ??
          const <String>[];
      out.add(
        VibeAgentProfile(
          id: id,
          displayName: name,
          provider: provider,
          modelId: modelId,
          systemPrompt: (a['systemPrompt'] as String?) ?? '',
          toolNames: tools,
          role: _parseAgentRole(a['role'] as String?),
        ),
      );
    }
    return out;
  } catch (_) {
    return const <VibeAgentProfile>[];
  }
}

mk.AgentRole _parseAgentRole(String? raw) {
  switch ((raw ?? 'worker').toLowerCase()) {
    case 'manager':
      return mk.AgentRole.manager;
    case 'reviewer':
      return mk.AgentRole.reviewer;
    default:
      return mk.AgentRole.worker;
  }
}
