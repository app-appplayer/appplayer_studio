/// Disk-backed storage stack for `mcp_fact_graph`.
///
/// Each storage subclasses the exported `InMemory*Storage` base, overriding
/// only the mutating methods to flush the affected collection to disk after
/// the in-memory write. All query and index logic is reused unchanged — the
/// subclass adds durability, not behaviour.
///
/// Layout: one JSON-array file per collection under [PersistentStorageContainer.rootDir]
/// (e.g. `<projectRoot>/.factgraph/facts.json`). Write-through means a crash
/// loses nothing already returned from a `save*`/`delete*` call.
library;

import 'package:mcp_fact_graph/mcp_fact_graph.dart';
// The five *Query types whose names overlap with mcp_bundle (Claim/Entity/
// Fact/Pattern/RunQuery) are hidden from the public barrel; reach them by path
// for the "query all" flush calls below. Harmless here — this file does not
// import mcp_bundle, so there is no ambiguity.
import 'package:mcp_fact_graph/src/ports/storage_port.dart'
    show ClaimQuery, EntityQuery, FactQuery, PatternQuery, RunQuery;

import 'collection_file.dart';

// =============================================================================
// L0 — Evidence (+ fragments)
// =============================================================================

class PersistentEvidenceStorage extends InMemoryEvidenceStorage {
  PersistentEvidenceStorage(String rootDir)
      : _evidenceFile = CollectionFile(rootDir, 'evidence'),
        _fragmentsFile = CollectionFile(rootDir, 'fragments');

  final CollectionFile _evidenceFile;
  final CollectionFile _fragmentsFile;

  Future<void> load() async {
    for (final j in await _evidenceFile.read()) {
      await super.saveEvidence(Evidence.fromJson(j));
    }
    final fragments =
        (await _fragmentsFile.read()).map(Fragment.fromJson).toList();
    if (fragments.isNotEmpty) await super.saveFragments(fragments);
  }

  Future<void> _flushEvidence() async {
    final all = await super.queryEvidence(const EvidenceQuery());
    await _evidenceFile.write(all.map((e) => e.toJson()).toList());
  }

  Future<void> _flushFragments() async {
    final all = <Map<String, dynamic>>[];
    for (final e in await super.queryEvidence(const EvidenceQuery())) {
      for (final f in await super.getFragments(e.evidenceId)) {
        all.add(f.toJson());
      }
    }
    await _fragmentsFile.write(all);
  }

  @override
  Future<void> saveEvidence(Evidence evidence) async {
    await super.saveEvidence(evidence);
    await _flushEvidence();
  }

  @override
  Future<void> deleteEvidence(String evidenceId) async {
    await super.deleteEvidence(evidenceId);
    await _flushEvidence();
    await _flushFragments();
  }

  @override
  Future<void> saveFragments(List<Fragment> fragments) async {
    await super.saveFragments(fragments);
    await _flushFragments();
  }
}

// =============================================================================
// L1 — Candidate
// =============================================================================

class PersistentCandidateStorage extends InMemoryCandidateStorage {
  PersistentCandidateStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'candidates');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveCandidate(Candidate.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryCandidates(const CandidateQuery());
    await _file.write(all.map((c) => c.toJson()).toList());
  }

  @override
  Future<void> saveCandidate(Candidate candidate) async {
    await super.saveCandidate(candidate);
    await _flush();
  }

  @override
  Future<void> updateCandidateStatus(
      String candidateId, CandidateStatus status) async {
    await super.updateCandidateStatus(candidateId, status);
    await _flush();
  }

  @override
  Future<void> deleteCandidate(String candidateId) async {
    await super.deleteCandidate(candidateId);
    await _flush();
  }
}

// =============================================================================
// L1 — Entity
// =============================================================================

class PersistentEntityStorage extends InMemoryEntityStorage {
  PersistentEntityStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'entities');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveEntity(Entity.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryEntities(const EntityQuery());
    await _file.write(all.map((e) => e.toJson()).toList());
  }

  @override
  Future<void> saveEntity(Entity entity) async {
    await super.saveEntity(entity);
    await _flush();
  }

  @override
  Future<void> deleteEntity(String entityId) async {
    await super.deleteEntity(entityId);
    await _flush();
  }
}

// =============================================================================
// L1 — Fact
// =============================================================================

class PersistentFactStorage extends InMemoryFactStorage {
  PersistentFactStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'facts');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveFact(Fact.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryFacts(const FactQuery());
    await _file.write(all.map((f) => f.toJson()).toList());
  }

  @override
  Future<void> saveFact(Fact fact) async {
    await super.saveFact(fact);
    await _flush();
  }

  @override
  Future<void> deleteFact(String factId) async {
    await super.deleteFact(factId);
    await _flush();
  }
}

// =============================================================================
// L1 — View
// =============================================================================

class PersistentViewStorage extends InMemoryViewStorage {
  PersistentViewStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'views');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveView(View.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryViews(const ViewQuery());
    await _file.write(all.map((v) => v.toJson()).toList());
  }

  @override
  Future<void> saveView(View view) async {
    await super.saveView(view);
    await _flush();
  }

  @override
  Future<void> deleteView(String viewId) async {
    await super.deleteView(viewId);
    await _flush();
  }
}

// =============================================================================
// L2 — Context (bundles + summary nodes + claims)
// =============================================================================

class PersistentContextStorage extends InMemoryContextStorage {
  PersistentContextStorage(String rootDir)
      : _bundlesFile = CollectionFile(rootDir, 'context_bundles'),
        _summariesFile = CollectionFile(rootDir, 'summary_nodes'),
        _claimsFile = CollectionFile(rootDir, 'claims');

  final CollectionFile _bundlesFile;
  final CollectionFile _summariesFile;
  final CollectionFile _claimsFile;

  Future<void> load() async {
    for (final j in await _bundlesFile.read()) {
      await super.saveContextBundle(InternalContextBundle.fromJson(j));
    }
    for (final j in await _summariesFile.read()) {
      await super.saveSummaryNode(SummaryNode.fromJson(j));
    }
    for (final j in await _claimsFile.read()) {
      await super.saveClaim(VerifiableClaim.fromJson(j));
    }
  }

  Future<void> _flushBundles() async {
    final all = await super.queryContextBundles(const ContextBundleQuery());
    await _bundlesFile.write(all.map((b) => b.toJson()).toList());
  }

  Future<void> _flushSummaries() async {
    final all = await super.querySummaryNodes(const SummaryNodeQuery());
    await _summariesFile.write(all.map((s) => s.toJson()).toList());
  }

  Future<void> _flushClaims() async {
    final all = await super.queryClaims(const ClaimQuery());
    await _claimsFile.write(all.map((c) => c.toJson()).toList());
  }

  @override
  Future<void> saveContextBundle(InternalContextBundle bundle) async {
    await super.saveContextBundle(bundle);
    await _flushBundles();
  }

  @override
  Future<void> saveSummaryNode(SummaryNode node) async {
    await super.saveSummaryNode(node);
    await _flushSummaries();
  }

  @override
  Future<void> saveClaim(VerifiableClaim claim) async {
    await super.saveClaim(claim);
    await _flushClaims();
  }
}

// =============================================================================
// L3 — SkillOps (patterns + skills + rubrics + evaluation runs)
// =============================================================================

class PersistentSkillOpsStorage extends InMemorySkillOpsStorage {
  PersistentSkillOpsStorage(String rootDir)
      : _patternsFile = CollectionFile(rootDir, 'patterns'),
        _skillsFile = CollectionFile(rootDir, 'skills'),
        _rubricsFile = CollectionFile(rootDir, 'rubrics'),
        _evalRunsFile = CollectionFile(rootDir, 'evaluation_runs');

  final CollectionFile _patternsFile;
  final CollectionFile _skillsFile;
  final CollectionFile _rubricsFile;
  final CollectionFile _evalRunsFile;

  Future<void> load() async {
    for (final j in await _patternsFile.read()) {
      await super.savePattern(Pattern.fromJson(j));
    }
    for (final j in await _skillsFile.read()) {
      await super.saveSkill(Skill.fromJson(j));
    }
    for (final j in await _rubricsFile.read()) {
      await super.saveRubric(Rubric.fromJson(j));
    }
    for (final j in await _evalRunsFile.read()) {
      await super.saveEvaluationRun(EvaluationRun.fromJson(j));
    }
  }

  Future<void> _flushPatterns() async {
    final all = await super.queryPatterns(const PatternQuery());
    await _patternsFile.write(all.map((p) => p.toJson()).toList());
  }

  Future<void> _flushSkills() async {
    final all = await super.querySkills(const SkillQuery());
    await _skillsFile.write(all.map((s) => s.toJson()).toList());
  }

  Future<void> _flushRubrics() async {
    final all = await super.queryRubrics(const RubricQuery());
    await _rubricsFile.write(all.map((r) => r.toJson()).toList());
  }

  Future<void> _flushEvalRuns() async {
    final all = await super.queryEvaluationRuns(const EvaluationRunQuery());
    await _evalRunsFile.write(all.map((r) => r.toJson()).toList());
  }

  @override
  Future<void> savePattern(Pattern pattern) async {
    await super.savePattern(pattern);
    await _flushPatterns();
  }

  @override
  Future<void> saveSkill(Skill skill) async {
    await super.saveSkill(skill);
    await _flushSkills();
  }

  @override
  Future<void> saveRubric(Rubric rubric) async {
    await super.saveRubric(rubric);
    await _flushRubrics();
  }

  @override
  Future<void> saveEvaluationRun(EvaluationRun run) async {
    await super.saveEvaluationRun(run);
    await _flushEvalRuns();
  }
}

// =============================================================================
// L1 — Relation
// =============================================================================

class PersistentRelationStorage extends InMemoryRelationStorage {
  PersistentRelationStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'relations');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveRelation(Relation.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryRelations(const RelationQuery());
    await _file.write(all.map((r) => r.toJson()).toList());
  }

  @override
  Future<void> saveRelation(Relation relation) async {
    await super.saveRelation(relation);
    await _flush();
  }

  @override
  Future<void> deleteRelation(String relationId) async {
    await super.deleteRelation(relationId);
    await _flush();
  }
}

// =============================================================================
// Run
// =============================================================================

class PersistentRunStorage extends InMemoryRunStorage {
  PersistentRunStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'runs');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveRun(Run.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryRuns(const RunQuery());
    await _file.write(all.map((r) => r.toJson()).toList());
  }

  @override
  Future<void> saveRun(Run run) async {
    await super.saveRun(run);
    await _flush();
  }

  @override
  Future<void> deleteRun(String runId) async {
    await super.deleteRun(runId);
    await _flush();
  }
}

// =============================================================================
// Artifact
// =============================================================================

class PersistentArtifactStorage extends InMemoryArtifactStorage {
  PersistentArtifactStorage(String rootDir)
      : _file = CollectionFile(rootDir, 'artifacts');

  final CollectionFile _file;

  Future<void> load() async {
    for (final j in await _file.read()) {
      await super.saveArtifact(Artifact.fromJson(j));
    }
  }

  Future<void> _flush() async {
    final all = await super.queryArtifacts(const ArtifactQuery());
    await _file.write(all.map((a) => a.toJson()).toList());
  }

  @override
  Future<void> saveArtifact(Artifact artifact) async {
    await super.saveArtifact(artifact);
    await _flush();
  }

  @override
  Future<void> deleteArtifact(String artifactId) async {
    await super.deleteArtifact(artifactId);
    await _flush();
  }
}

// =============================================================================
// Container
// =============================================================================

/// Disk-backed counterpart of `InMemoryStorageContainer`. Holds the ten
/// storages the `FactGraphRuntime` primary constructor and its services
/// consume, each rooted under [rootDir]. Call [load] once before assembling
/// the runtime to hydrate from disk.
class PersistentStorageContainer {
  PersistentStorageContainer(this.rootDir)
      : evidence = PersistentEvidenceStorage(rootDir),
        candidates = PersistentCandidateStorage(rootDir),
        entities = PersistentEntityStorage(rootDir),
        facts = PersistentFactStorage(rootDir),
        views = PersistentViewStorage(rootDir),
        context = PersistentContextStorage(rootDir),
        skillOps = PersistentSkillOpsStorage(rootDir),
        relations = PersistentRelationStorage(rootDir),
        runs = PersistentRunStorage(rootDir),
        artifacts = PersistentArtifactStorage(rootDir);

  /// Directory holding the collection files (e.g. `<projectRoot>/.factgraph`).
  final String rootDir;

  final PersistentEvidenceStorage evidence;
  final PersistentCandidateStorage candidates;
  final PersistentEntityStorage entities;
  final PersistentFactStorage facts;
  final PersistentViewStorage views;
  final PersistentContextStorage context;
  final PersistentSkillOpsStorage skillOps;
  final PersistentRelationStorage relations;
  final PersistentRunStorage runs;
  final PersistentArtifactStorage artifacts;

  /// Hydrate every collection from disk. Safe on a fresh (empty) directory.
  Future<void> load() async {
    await evidence.load();
    await candidates.load();
    await entities.load();
    await facts.load();
    await views.load();
    await context.load();
    await skillOps.load();
    await relations.load();
    await runs.load();
    await artifacts.load();
  }
}
