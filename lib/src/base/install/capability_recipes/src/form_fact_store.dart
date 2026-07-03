/// Fact-backed persistence seam for form templates.
///
/// A form template is pure JSON data (`FormTemplate.toJson`). The Form Builder
/// wants templates — and their version history — to persist and *accumulate*
/// per project, through the same substrate as all other project knowledge:
/// the kernel's FactGraph. So rather than giving `mcp_form` its own storage,
/// each saved (templateId, version) is recorded as a **fact** in the project's
/// FactGraph (per-project path — the same store `knowledge_persistence` wires).
///
/// This file defines only the seam. The host binds [FormTemplateFactStore] to
/// its kernel — e.g. `bk.fact.write` / `bk.fact.query` on the active project's
/// `FactFacade` — so the recipe stays free of a hard `brain_kernel` fact
/// dependency and the host controls where facts live.
library;

/// One persisted template version — the unit stored as a fact.
///
/// `createdAt` is the issuance time of *that version*; it is preserved across
/// restarts (unlike re-hydrating an in-memory port, which would stamp "now").
class FormTemplateRecord {
  const FormTemplateRecord({
    required this.templateId,
    required this.version,
    required this.createdAt,
    required this.templateJson,
  });

  final String templateId;
  final String version;
  final DateTime createdAt;
  final Map<String, dynamic> templateJson;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'templateId': templateId,
        'version': version,
        'createdAt': createdAt.toIso8601String(),
        'template': templateJson,
      };

  factory FormTemplateRecord.fromJson(Map<String, dynamic> json) =>
      FormTemplateRecord(
        templateId: json['templateId'] as String,
        version: json['version'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        templateJson: (json['template'] as Map).cast<String, dynamic>(),
      );
}

/// Durable, per-project store for template version records.
///
/// Implementations persist to the kernel FactGraph (per-project). Ordering of
/// [loadAll] must follow save order (append order) so version history and the
/// "current" (latest) version resolve deterministically.
abstract interface class FormTemplateFactStore {
  /// Append a template version record. Durability is the implementation's
  /// responsibility; duplicate rejection is handled by the port above it.
  Future<void> append(FormTemplateRecord record);

  /// Every stored record, all templateIds and versions, in save order.
  Future<List<FormTemplateRecord>> loadAll();

  /// Remove a template's records — all versions, or a single [version].
  Future<void> remove(String templateId, {String? version});
}
