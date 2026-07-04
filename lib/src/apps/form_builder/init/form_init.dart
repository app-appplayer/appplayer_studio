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
  static const String approvalType = 'form_approval';

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

  // --- approvals (request → approval line → inbox) ------------------------
  //
  // One `form_approval` fact per documentId, latest wins (same upsert rule
  // as drafts — a re-submission after a rejection REPLACES the approval).
  // The line is an ordered list of gates; each act stamps provenance
  // (actedBy/actedAt/comment). Design:
  // `docs/form_builder/form-approval-line.md`. Authorization is the exact
  // designated approver (form projects carry no org tree, so the ops-style
  // ancestor escalation is out of scope here — MVP deviation noted in the
  // design doc).

  /// Open an approval for a saved draft. [line] entries:
  /// `{approverId, roleLabel?}`. Flips the draft status to `review`.
  Future<Map<String, dynamic>> requestApproval({
    required String documentId,
    required List<Map<String, dynamic>> line,
    required String requestedBy,
    String? title,
  }) async {
    if (line.isEmpty) {
      throw const FormApprovalError(
        'approval.empty_line',
        'an approval line needs at least one approver',
      );
    }
    final draft = await getDraft(documentId);
    if (draft == null) {
      throw const FormApprovalError(
        'approval.draft_not_found',
        'save the draft before requesting approval',
      );
    }
    final approval = <String, dynamic>{
      'documentId': documentId,
      'templateId': draft['document']?['templateId'],
      if (title != null) 'title': title,
      'requestedBy': requestedBy,
      'requestedAt': DateTime.now().toUtc().toIso8601String(),
      'line': [
        for (final e in line)
          <String, dynamic>{
            'approverId': e['approverId'],
            if (e['roleLabel'] != null) 'roleLabel': e['roleLabel'],
            'status': 'pending',
          },
      ],
      'currentIndex': 0,
      'state': 'pending',
    };
    await _writeApproval(approval);
    await _setDraftStatus(documentId, 'review');
    return approval;
  }

  /// Approve the CURRENT gate as [actor]. [finalize] skips the remaining
  /// gates and completes the whole approval now.
  Future<Map<String, dynamic>> approve({
    required String documentId,
    required String actor,
    String? comment,
    bool finalize = false,
  }) async {
    final approval = await _pendingApprovalFor(documentId, actor);
    final line = (approval['line'] as List).cast<Map<String, dynamic>>();
    final index = approval['currentIndex'] as int;
    line[index] = <String, dynamic>{
      ...line[index],
      'status': 'approved',
      'actedBy': actor,
      'actedAt': DateTime.now().toUtc().toIso8601String(),
      if (comment != null) 'comment': comment,
    };
    var next = index + 1;
    if (finalize) {
      for (var i = next; i < line.length; i++) {
        line[i] = <String, dynamic>{...line[i], 'status': 'skipped'};
      }
      next = line.length;
    }
    approval['currentIndex'] = next;
    if (next >= line.length) {
      approval['state'] = 'approved';
      approval['approvedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    await _writeApproval(approval);
    if (approval['state'] == 'approved') {
      await _setDraftStatus(documentId, 'approved');
    }
    return approval;
  }

  /// Reject at the CURRENT gate as [actor]. A rejection needs its reason —
  /// the drafter reads it to fix and re-submit (a NEW approval).
  Future<Map<String, dynamic>> reject({
    required String documentId,
    required String actor,
    required String comment,
  }) async {
    if (comment.trim().isEmpty) {
      throw const FormApprovalError(
        'approval.comment_required',
        'a rejection must say why',
      );
    }
    final approval = await _pendingApprovalFor(documentId, actor);
    final line = (approval['line'] as List).cast<Map<String, dynamic>>();
    final index = approval['currentIndex'] as int;
    line[index] = <String, dynamic>{
      ...line[index],
      'status': 'rejected',
      'actedBy': actor,
      'actedAt': DateTime.now().toUtc().toIso8601String(),
      'comment': comment,
    };
    approval['state'] = 'rejected';
    await _writeApproval(approval);
    await _setDraftStatus(documentId, 'draft');
    return approval;
  }

  /// Withdraw a pending approval — only its requester may.
  Future<Map<String, dynamic>> withdrawApproval({
    required String documentId,
    required String actor,
  }) async {
    final approval = await getApproval(documentId);
    if (approval == null || approval['state'] != 'pending') {
      throw const FormApprovalError(
        'approval.not_pending',
        'no pending approval for this document',
      );
    }
    if (approval['requestedBy'] != actor) {
      throw FormApprovalError(
        'approval.not_requester',
        'only ${approval['requestedBy']} may withdraw this request',
      );
    }
    approval['state'] = 'withdrawn';
    await _writeApproval(approval);
    await _setDraftStatus(documentId, 'draft');
    return approval;
  }

  /// Move an approval to a new documentId. Compose re-materialises the
  /// engine document on every draft load (a NEW documentId), so the draft
  /// is re-keyed — the approval must travel with it or the document
  /// detaches from its approval (live-caught 2026-07-04: an issued
  /// document lost its provenance, and a PENDING line could be bypassed).
  Future<void> rekeyApproval({
    required String from,
    required String to,
  }) async {
    if (from == to) return;
    final approval = await getApproval(from);
    if (approval == null) return;
    approval['documentId'] = to;
    await system.facts.deleteFacts(<String>['$approvalType/$from']);
    await _writeApproval(approval);
  }

  Future<Map<String, dynamic>?> getApproval(String documentId) async {
    final hits = await system.facts.queryFacts(
      FactQuery(
        workspaceId: projectId,
        types: const [approvalType],
        entityId: documentId,
        limit: 1,
      ),
    );
    return hits.isEmpty ? null : hits.single.content;
  }

  Future<List<Map<String, dynamic>>> listApprovals() async {
    final hits = await system.facts.queryFacts(
      FactQuery(
        workspaceId: projectId,
        types: const [approvalType],
        limit: 1000,
      ),
    );
    final approvals = hits.map((f) => f.content).toList();
    approvals.sort(
      (a, b) => (b['requestedAt'] as String? ?? '').compareTo(
        a['requestedAt'] as String? ?? '',
      ),
    );
    return approvals;
  }

  Future<Map<String, dynamic>> _pendingApprovalFor(
    String documentId,
    String actor,
  ) async {
    final approval = await getApproval(documentId);
    if (approval == null || approval['state'] != 'pending') {
      throw const FormApprovalError(
        'approval.not_pending',
        'no pending approval for this document',
      );
    }
    final line = (approval['line'] as List).cast<Map<String, dynamic>>();
    final index = approval['currentIndex'] as int;
    final designated = line[index]['approverId'];
    if (designated != actor) {
      throw FormApprovalError(
        'approval.not_your_gate',
        'the current gate belongs to $designated',
      );
    }
    return approval;
  }

  Future<void> _writeApproval(Map<String, dynamic> approval) async {
    final documentId = approval['documentId'] as String;
    await system.facts.deleteFacts(<String>['$approvalType/$documentId']);
    await system.facts.writeFacts(<FactRecord>[
      FactRecord(
        id: '$approvalType/$documentId',
        workspaceId: projectId,
        type: approvalType,
        entityId: documentId,
        content: approval,
        confidence: 1.0,
        createdAt: DateTime.now(),
      ),
    ]);
  }

  Future<void> _setDraftStatus(String documentId, String status) async {
    final draft = await getDraft(documentId);
    if (draft == null) return;
    await saveDraft(
      documentId: documentId,
      document:
          (draft['document'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      status: status,
      savedBy: draft['savedBy'] as String?,
    );
  }
}

/// Domain error with a stable code — the tool layer maps it onto the
/// response envelope so an LLM reads the code and self-corrects.
class FormApprovalError implements Exception {
  const FormApprovalError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
