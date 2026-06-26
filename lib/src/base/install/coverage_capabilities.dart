/// Capability-coverage tool packs — canvas / kv / analysis / datastore(fs+db),
/// adopted through the vendored `capability_tools` recipe.
///
/// Host **wiring only** (no business logic — the tool logic lives in the
/// recipe / the `mcp_*` packages). This function configures the host-side
/// adapters (kv root, the analysis standard engine, a datastore fs source
/// jailed to the config root + a sqlite db source) and the datastore policy
/// (manager/operator roles, destructive plan→commit), then exposes each pack
/// as `<id>.*` on the shared [mk.HostToolRegistry].
///
/// Factored out of `VibeStudioHostApp.registerMcpTools` so the wiring — the
/// exposed surface and the policy/jail configuration — is unit-testable
/// without booting the full app.
library;

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:mcp_datastore/mcp_datastore.dart';
import 'package:mcp_datastore_sqlite/mcp_datastore_sqlite.dart';

import 'capability_recipes/capability_recipes.dart';

/// Result of [registerCoverageCapabilities]: the exposed tool names plus a
/// [ready] future that completes when the sqlite db source has opened. The
/// host ignores [ready] (db.* serves once open completes; fs.* is ready
/// immediately); a test awaits it before exercising `db.*`.
class CoverageCapabilities {
  const CoverageCapabilities({required this.toolNames, required this.ready});

  /// Every exposed name across the five packs (`canvas.*`, `kv.*`,
  /// `analysis.*`, `fs.*`, `db.*`).
  final List<String> toolNames;

  /// Completes when the sqlite source finishes opening.
  final Future<void> ready;
}

/// Register the coverage capability packs onto [registry], rooting all
/// host-side storage under [capRoot].
CoverageCapabilities registerCoverageCapabilities(
  mk.HostToolRegistry registry, {
  required String capRoot,
}) {
  final names = <String>[];

  names.addAll(
    registerCapabilityTools(
      registry,
      capabilityId: canvasCapabilityId,
      tools: canvasCapabilityTools(),
    ),
  );
  names.addAll(
    registerCapabilityTools(
      registry,
      capabilityId: kvCapabilityId,
      tools: kvCapabilityTools(
        mk.KvStoragePortAdapter(rootDir: p.join(capRoot, 'kv')),
      ),
    ),
  );
  names.addAll(
    registerCapabilityTools(
      registry,
      capabilityId: analysisCapabilityId,
      tools: analysisCapabilityTools(standardAnalysisPort()),
    ),
  );

  final dsReg =
      DatasourceRegistry()..register(FilesystemSource(id: 'ws', root: capRoot));
  final sqlite = SqliteSource(
    id: 'main',
    path: p.join(capRoot, 'datastore.db'),
  );
  final ready = sqlite.open();
  dsReg.register(sqlite);
  final ds = DatastoreTools(
    registry: dsReg,
    policy: DatastorePolicy(
      allowedRoles: const <String>{'manager', 'operator'},
      requireCommitForDestructive: true,
    ),
  );
  names.addAll(
    registerCapabilityTools(
      registry,
      capabilityId: fsCapabilityId,
      tools: fsCapabilityTools(ds),
    ),
  );
  names.addAll(
    registerCapabilityTools(
      registry,
      capabilityId: dbCapabilityId,
      tools: dbCapabilityTools(ds),
    ),
  );

  return CoverageCapabilities(toolNames: names, ready: ready);
}
