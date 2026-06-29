/// Per-project assembly of a disk-backed `FactGraphRuntime` / `KnowledgeSystem`,
/// plus project-level purge and export/import.
///
/// The persistence backend is injected through the public constructors only —
/// `mcp_fact_graph` and `mcp_knowledge` cores are unchanged. [assemblePersistentFactGraph]
/// mirrors `FactGraphRuntime.inMemory`'s service wiring but with the
/// disk-backed [PersistentStorageContainer]. Each project gets its OWN runtime
/// (and KnowledgeSystem) rooted in its own folder — isolation falls out of
/// distinct root directories, not runtime rebinding.
library;

import 'dart:io';

// mcp_knowledge re-exports the mcp_fact_graph surface (runtime, services,
// adapters, storage ports), so a single import covers both.
import 'package:mcp_knowledge/mcp_knowledge.dart';

import 'collection_file.dart';
import 'persistent_storage.dart';

/// All collection file base-names, in load/export order.
const List<String> kCollectionNames = [
  'evidence',
  'fragments',
  'candidates',
  'entities',
  'facts',
  'views',
  'context_bundles',
  'summary_nodes',
  'claims',
  'patterns',
  'skills',
  'rubrics',
  'evaluation_runs',
  'relations',
  'runs',
  'artifacts',
];

/// Default sub-directory placed inside a project root to hold the graph.
const String kFactGraphDirName = '.factgraph';

/// Resolve the on-disk graph directory for a project root.
String factGraphDirFor(String projectRoot) =>
    '$projectRoot/$kFactGraphDirName';

/// Assemble a disk-backed [FactGraphRuntime] rooted at [rootDir], hydrated
/// from any existing collection files. Mirrors the service wiring of
/// `FactGraphRuntime.inMemory` so behaviour is identical apart from durability.
Future<FactGraphRuntime> assemblePersistentFactGraph({
  required String rootDir,
  String defaultWorkspaceId = 'default',
  String defaultPolicyVersion = 'v1',
  bool enablePatternMining = true,
  bool enableSummaryScheduler = true,
  bool enableConsistencyCheck = true,
  bool enableCandidateDedup = true,
}) async {
  final container = PersistentStorageContainer(rootDir);
  await container.load();

  final evidenceService = EvidenceService(storage: container.evidence);
  final factGraphService = FactGraphService(
    candidateStorage: container.candidates,
    entityStorage: container.entities,
    factStorage: container.facts,
    viewStorage: container.views,
  );
  final contextService = ContextService(
    storage: container.context,
    factStorage: container.facts,
  );
  final skillOpsService = SkillOpsService(storage: container.skillOps);

  final patternsPort = PatternsPortAdapter(
    skillOpsStoragePort: container.skillOps,
    defaultWorkspaceId: defaultWorkspaceId,
  );
  final patternMiner = PatternMiner(
    factStorage: container.facts,
    patternStorage: patternsPort,
    enabled: enablePatternMining,
  );
  final summariesPort = SummariesPortAdapter(
    contextStoragePort: container.context,
    defaultWorkspaceId: defaultWorkspaceId,
  );
  final summaryScheduler = SummaryScheduler(
    summaries: summariesPort,
    enabled: enableSummaryScheduler,
  );
  final consistencyChecker = ConsistencyChecker(
    storage: container.facts,
    enabled: enableConsistencyCheck,
  );
  final candidateDeduplicator = CandidateDeduplicator(
    storage: container.candidates,
    enabled: enableCandidateDedup,
  );

  return FactGraphRuntime(
    evidenceService: evidenceService,
    factGraphService: factGraphService,
    contextService: contextService,
    skillOpsService: skillOpsService,
    evidenceStoragePort: container.evidence,
    candidateStoragePort: container.candidates,
    entityStoragePort: container.entities,
    factStoragePort: container.facts,
    contextStoragePort: container.context,
    skillOpsStoragePort: container.skillOps,
    relationStoragePort: container.relations,
    runStoragePort: container.runs,
    artifactStoragePort: container.artifacts,
    patternMiner: patternMiner,
    summaryScheduler: summaryScheduler,
    consistencyChecker: consistencyChecker,
    candidateDeduplicator: candidateDeduplicator,
    defaultWorkspaceId: defaultWorkspaceId,
    defaultPolicyVersion: defaultPolicyVersion,
  );
}

/// Assemble a per-project [KnowledgeSystem] whose L0 FactGraph persists under
/// `<projectRoot>/.factgraph`. The project id doubles as the workspace id, so
/// queries stay project-scoped. Two projects = two roots = two systems = full
/// isolation, with no shared global accumulation.
Future<KnowledgeSystem> assemblePersistentKnowledgeSystem({
  required String projectRoot,
  required String projectId,
  KnowledgeConfig? config,
  KnowledgePorts? ports,
  String? graphDir,
}) async {
  final factGraph = await assemblePersistentFactGraph(
    rootDir: graphDir ?? factGraphDirFor(projectRoot),
    defaultWorkspaceId: projectId,
  );
  return KnowledgeSystem(
    config: (config ?? KnowledgeConfig.defaults).copyWith(
      workspaceId: projectId,
    ),
    ports: ports,
    factGraph: factGraph,
  );
}

/// Project-level purge: remove the entire on-disk graph directory. This is the
/// complete, reliable purge for the per-project model — the project's facts
/// live only here. Pass the graph dir (e.g. [factGraphDirFor]).
Future<void> purgeProject(String graphDir) async {
  final dir = Directory(graphDir);
  if (await dir.exists()) await dir.delete(recursive: true);
}

/// Export a project's full graph as a portable map keyed by collection name.
/// Equivalent to copying the folder, but as a single serializable value for
/// backup or transfer. Reads the on-disk files directly.
Future<Map<String, List<Map<String, dynamic>>>> exportProject(
    String graphDir) async {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final name in kCollectionNames) {
    final items = await CollectionFile(graphDir, name).read();
    if (items.isNotEmpty) out[name] = items;
  }
  return out;
}

/// Import a previously [exportProject]-ed map into [graphDir], replacing any
/// existing collections. Assemble a runtime against [graphDir] afterwards to
/// use the imported graph.
Future<void> importProject(
  String graphDir,
  Map<String, List<Map<String, dynamic>>> data,
) async {
  for (final name in kCollectionNames) {
    final items = data[name];
    if (items != null) await CollectionFile(graphDir, name).write(items);
  }
}
