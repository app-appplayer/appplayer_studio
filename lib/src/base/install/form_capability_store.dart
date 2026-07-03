/// Kernel binding for the form capability's template persistence.
///
/// The vendored `capability_tools` recipe defines the seam
/// ([FormTemplateFactStore]) and the drop-in port
/// ([FactBackedFormTemplatePort]); this file binds the seam to the kernel:
/// each saved template version becomes one `form_template` fact in the bound
/// project's FactGraph — the same per-project store `knowledge_persistence`
/// wires (`<projectRoot>/.factgraph`), so templates and their version history
/// accumulate per project and survive restarts.
///
/// Project scoping: the form capability registration is host-level but the
/// facts are per-project, so the Form Builder REBINDS the `form.*`
/// registration on project bind/close ([bindFormCapabilityTemplates] /
/// `registerFormCapability()` for the unbound in-memory default), relying on
/// `registerExposed`'s replace-on-reregister semantics. A statically hydrated
/// port would leak one project's templates into another.
library;

import 'package:brain_kernel/brain_kernel.dart' show HostToolRegistry;
import 'package:mcp_bundle/mcp_bundle.dart' show FactQuery, FactRecord;
import 'package:mcp_knowledge/mcp_knowledge.dart' show FactFacade;

import 'capability_recipes/capability_recipes.dart'
    show FactBackedFormTemplatePort, FormTemplateFactStore, FormTemplateRecord;
import 'capability_tools.dart' show registerFormCapability;

/// [FormTemplateFactStore] over a kernel [FactFacade].
///
/// One fact per (templateId, version):
///   - `id` = `form_template/<templateId>@<version>` (unique — the port
///     rejects duplicates before append)
///   - `type` = `form_template`, `entityId` = templateId
///   - `content` = `FormTemplateRecord.toJson()` + a monotonic `seq`, so
///     [loadAll] can restore SAVE ORDER deterministically even when two
///     versions share a createdAt millisecond (the recipe contract: last
///     record per templateId = its current version).
class KernelFormTemplateFactStore implements FormTemplateFactStore {
  KernelFormTemplateFactStore({
    required FactFacade facts,
    required String workspaceId,
  }) : _facts = facts,
       _workspaceId = workspaceId;

  static const String factType = 'form_template';

  final FactFacade _facts;
  final String _workspaceId;
  int? _nextSeq; // lazily initialised from the max persisted seq

  String _factId(String templateId, String version) =>
      '$factType/$templateId@$version';

  Future<List<FactRecord>> _queryAll() async {
    final records = await _facts.queryFacts(
      FactQuery(
        workspaceId: _workspaceId,
        types: const [factType],
        limit: 100000,
      ),
    );
    return records;
  }

  int _seqOf(FactRecord r) => (r.content['seq'] as num?)?.toInt() ?? 0;

  @override
  Future<void> append(FormTemplateRecord record) async {
    if (_nextSeq == null) {
      final existing = await _queryAll();
      _nextSeq = existing.isEmpty
          ? 0
          : existing.map(_seqOf).reduce((a, b) => a > b ? a : b) + 1;
    }
    final seq = _nextSeq!;
    _nextSeq = seq + 1;
    await _facts.writeFacts(<FactRecord>[
      FactRecord(
        id: _factId(record.templateId, record.version),
        workspaceId: _workspaceId,
        type: factType,
        entityId: record.templateId,
        content: <String, dynamic>{...record.toJson(), 'seq': seq},
        confidence: 1.0,
        createdAt: record.createdAt,
      ),
    ]);
  }

  @override
  Future<List<FormTemplateRecord>> loadAll() async {
    final records = await _queryAll();
    records.sort((a, b) => _seqOf(a).compareTo(_seqOf(b)));
    return <FormTemplateRecord>[
      for (final r in records)
        FormTemplateRecord.fromJson(
          // Strip the store-level ordering key; the recipe record is the
          // payload contract.
          <String, dynamic>{...r.content}..remove('seq'),
        ),
    ];
  }

  @override
  Future<void> remove(String templateId, {String? version}) async {
    if (version != null) {
      await _facts.deleteFacts(<String>[_factId(templateId, version)]);
      return;
    }
    final records = await _queryAll();
    final ids = <String>[
      for (final r in records)
        if (r.entityId == templateId) r.id,
    ];
    if (ids.isNotEmpty) await _facts.deleteFacts(ids);
  }
}

/// Rebind the host `form.*` registration so templates persist in [facts]
/// (the bound project's FactGraph, workspace-scoped by [workspaceId] — the
/// project id under the per-project `knowledge_persistence` model). Returns
/// the exposed tool names. Call `registerFormCapability(registry)` (no port)
/// to fall back to the unbound in-memory default on project close.
Future<List<String>> bindFormCapabilityTemplates(
  HostToolRegistry registry, {
  required FactFacade facts,
  required String workspaceId,
}) async {
  final store = KernelFormTemplateFactStore(
    facts: facts,
    workspaceId: workspaceId,
  );
  final port = await FactBackedFormTemplatePort.hydrate(store);
  return registerFormCapability(registry, templatePort: port);
}

/// Built-in-facing seam for the project rebind. The `form.*` registration
/// lives on the host's [HostToolRegistry], which built-ins must not import
/// (builtin-os-cleanup: no direct `brain_kernel`); the host installs its
/// registry here at boot (right after the initial `registerFormCapability`),
/// and the Form Builder calls [bindProject] / [unbindProject] on project
/// bind / close with only kernel-facade types.
class FormCapabilityBinding {
  FormCapabilityBinding._();

  static HostToolRegistry? _registry;

  /// Host boot hook — capture the registry the `form.*` tools live on.
  static void install(HostToolRegistry registry) => _registry = registry;

  /// Re-register `form.*` over the bound project's facts. No-op (false)
  /// when the host has not installed a registry (tests / headless).
  static Future<bool> bindProject({
    required FactFacade facts,
    required String workspaceId,
  }) async {
    final registry = _registry;
    if (registry == null) return false;
    await bindFormCapabilityTemplates(
      registry,
      facts: facts,
      workspaceId: workspaceId,
    );
    return true;
  }

  /// Fall back to the unbound in-memory default (project closed).
  static bool unbindProject() {
    final registry = _registry;
    if (registry == null) return false;
    registerFormCapability(registry);
    return true;
  }
}
