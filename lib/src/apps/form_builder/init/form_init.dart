/// Per-project core of the Form Builder built-in.
///
/// One bound project = one disk-backed `KnowledgeSystem`
/// (`<projectRoot>/.factgraph`, the same `knowledge_persistence` assembly Ops
/// uses) holding the app's document-management records as facts:
///
///   - `form_template` — written through the host `form.*` capability, which
///     `FormBuilderBuiltInApp.ensureBoot` rebinds onto this project's facts
///     (`FormCapabilityBinding.bindProject`) so `form.save_template` &co
///     persist here. Rebound back to the in-memory default on project close.
///   - `form_draft`    — one fact per documentId, latest wins (fact id is the
///     upsert key), written on EXPLICIT save.
///   - `form_issue`    — one IMMUTABLE fact per issued snapshot (+ artifacts
///     under `<projectRoot>/forms/<issueNumber>/`), `supersedes` links for
///     corrections.
///
/// Content data (org rosters, ledgers, …) is out of scope by design — that
/// belongs to the knowledge/execution system (Ops); this store carries only
/// the app's own document-management records.
library;

import 'package:mcp_bundle/mcp_bundle.dart' show FactQuery, FactRecord;
// The per-project system assembled by the vendored `knowledge_persistence`
// recipe is the mcp_knowledge orchestrator (NOT flowbrain's same-named
// wrapper class exported by builtin_api) — import the matching type.
import 'package:mcp_knowledge/mcp_knowledge.dart' show KnowledgeSystem;

import '../../../base/install/knowledge_persistence/knowledge_persistence.dart'
    show assemblePersistentKnowledgeSystem;

class FormInit {
  FormInit._({
    required this.projectRoot,
    required this.projectId,
    required this.system,
  });

  final String projectRoot;

  /// Doubles as the FactGraph workspace id (per-project model — same rule as
  /// `knowledge_persistence`).
  final String projectId;

  final KnowledgeSystem system;

  static const String draftType = 'form_draft';
  static const String issueType = 'form_issue';

  /// Assemble the per-project system. Pure assembly — the host `form.*`
  /// capability rebind is `FormBuilderBuiltInApp.ensureBoot`'s job (after
  /// its staleness check), so a boot that loses a rapid-rebind race can
  /// never clobber the newer project's binding.
  static Future<FormInit> boot(String projectRoot, String projectId) async {
    final system = await assemblePersistentKnowledgeSystem(
      projectRoot: projectRoot,
      projectId: projectId,
    );
    return FormInit._(
      projectRoot: projectRoot,
      projectId: projectId,
      system: system,
    );
  }

  /// Release the project's resources. The FactGraph needs no teardown —
  /// every write is already on disk (write-through). The `form.*` unbind is
  /// `FormBuilderBuiltInApp.closeProject`'s job (binding ownership lives
  /// with the boot cache, not the init).
  Future<void> dispose() async {}

  // --- drafts -----------------------------------------------------------

  Future<void> saveDraft({
    required String documentId,
    required Map<String, dynamic> document,
    required String status,
    String? savedBy,
  }) async {
    // Latest save wins by REPLACING the fact. The facade's write path
    // rejects a duplicate factId (FactConflictException — live-verified
    // 2026-07-03; raw storage upserts, the service layer does not), so a
    // re-save must delete-then-write.
    await system.facts.deleteFacts(<String>['$draftType/$documentId']);
    await system.facts.writeFacts(<FactRecord>[
      FactRecord(
        id: '$draftType/$documentId', // stable id — one working copy per doc
        workspaceId: projectId,
        type: draftType,
        entityId: documentId,
        content: <String, dynamic>{
          'documentId': documentId,
          'document': document,
          'status': status,
          if (savedBy != null) 'savedBy': savedBy,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
        confidence: 1.0,
        createdAt: DateTime.now(),
      ),
    ]);
  }

  Future<Map<String, dynamic>?> getDraft(String documentId) async {
    final hits = await system.facts.queryFacts(
      FactQuery(
        workspaceId: projectId,
        types: const [draftType],
        entityId: documentId,
        limit: 1,
      ),
    );
    return hits.isEmpty ? null : hits.single.content;
  }

  Future<List<Map<String, dynamic>>> listDrafts() async {
    final hits = await system.facts.queryFacts(
      FactQuery(workspaceId: projectId, types: const [draftType], limit: 1000),
    );
    final drafts = hits.map((f) => f.content).toList();
    drafts.sort(
      (a, b) => (b['updatedAt'] as String? ?? '').compareTo(
        a['updatedAt'] as String? ?? '',
      ),
    );
    return drafts;
  }

  Future<void> deleteDraft(String documentId) async {
    await system.facts.deleteFacts(<String>['$draftType/$documentId']);
  }

  // --- issues (immutable snapshots) --------------------------------------

  Future<List<Map<String, dynamic>>> listIssues() async {
    final hits = await system.facts.queryFacts(
      FactQuery(workspaceId: projectId, types: const [issueType], limit: 10000),
    );
    final issues = hits.map((f) => f.content).toList();
    issues.sort(
      (a, b) => (b['issuedAt'] as String? ?? '').compareTo(
        a['issuedAt'] as String? ?? '',
      ),
    );
    return issues;
  }

  Future<Map<String, dynamic>?> getIssue(String issueId) async {
    final hits = await system.facts.queryFacts(
      FactQuery(
        workspaceId: projectId,
        types: const [issueType],
        entityId: issueId,
        limit: 1,
      ),
    );
    return hits.isEmpty ? null : hits.single.content;
  }

  /// Allocate the next issue number (`<year>-<NNN>`) from the issued facts
  /// themselves — the max persisted sequence for the year + 1, so numbering
  /// survives restarts without a separate counter store.
  Future<String> nextIssueNumber() async {
    final year = DateTime.now().toUtc().year.toString();
    var max = 0;
    for (final issue in await listIssues()) {
      final number = issue['issueNumber'] as String? ?? '';
      final parts = number.split('-');
      if (parts.length == 2 && parts[0] == year) {
        final n = int.tryParse(parts[1]) ?? 0;
        if (n > max) max = n;
      }
    }
    return '$year-${(max + 1).toString().padLeft(3, '0')}';
  }

  /// Record an issued snapshot. The record is IMMUTABLE by contract — a
  /// correction is a NEW issue whose `supersedes` names this one.
  Future<void> recordIssue(Map<String, dynamic> issue) async {
    final issueId = issue['issueId'] as String;
    await system.facts.writeFacts(<FactRecord>[
      FactRecord(
        id: '$issueType/$issueId',
        workspaceId: projectId,
        type: issueType,
        entityId: issueId,
        content: issue,
        confidence: 1.0,
        createdAt: DateTime.now(),
      ),
    ]);
  }
}
