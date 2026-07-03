/// A [FormTemplatePort] whose templates + version history live in the project
/// FactGraph (via a [FormTemplateFactStore]), not in process memory.
///
/// Drop-in for `FormTemplatePortImpl`: same contract (schema validation,
/// duplicate templateId+version rejection, version history), but every save is
/// also written through to facts and the port hydrates from facts at boot — so
/// templates and their history accumulate per project and survive restarts.
///
/// Wire it into the form capability with
/// `formCapabilityTools(templatePort: await FactBackedFormTemplatePort.hydrate(store))`.
library;

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_form/mcp_form.dart' show validateSchema;

import 'form_fact_store.dart';

class FactBackedFormTemplatePort implements FormTemplatePort {
  FactBackedFormTemplatePort._(this._store, this._records);

  final FormTemplateFactStore _store;

  /// In-save-order records, the hot index rebuilt from [FormTemplateFactStore]
  /// at [hydrate]. The last record for a templateId is its current version.
  final List<FormTemplateRecord> _records;

  /// Build a port and load existing template facts into its hot index.
  static Future<FactBackedFormTemplatePort> hydrate(
    FormTemplateFactStore store,
  ) async {
    final records = await store.loadAll();
    return FactBackedFormTemplatePort._(store, List.of(records));
  }

  FormTemplateRecord? _currentRecord(String templateId) {
    FormTemplateRecord? current;
    for (final r in _records) {
      if (r.templateId == templateId) current = r; // last wins = current
    }
    return current;
  }

  @override
  Future<FormResult<FormTemplate>> saveTemplate({
    required FormTemplate template,
  }) async {
    // FR-TMPL-001: reject a duplicate templateId+version.
    final dup = _records.any((r) =>
        r.templateId == template.templateId && r.version == template.version);
    if (dup) {
      return FormResult.fail(FormError(
        code: 'template.duplicate',
        message: 'Template "${template.templateId}" version '
            '"${template.version}" already exists',
        path: '/templateId',
      ));
    }

    // FR-TMPL-002: schema must have at least one valid field.
    final schemaErrors = validateSchema(template.schema);
    if (schemaErrors.isNotEmpty) {
      return FormResult.fail(FormError(
        code: 'template.invalid_schema',
        message:
            'Template schema validation failed: ${schemaErrors.first.message}',
        path: '/schema',
      ));
    }

    final record = FormTemplateRecord(
      templateId: template.templateId,
      version: template.version,
      createdAt: DateTime.now(),
      templateJson: template.toJson(),
    );
    await _store.append(record); // durable write-through
    _records.add(record);
    return FormResult.ok(template);
  }

  @override
  Future<FormResult<FormTemplate>> getTemplate({
    required String templateId,
    String? version,
  }) async {
    final record = version == null
        ? _currentRecord(templateId)
        : _records.firstWhereOrNull(
            (r) => r.templateId == templateId && r.version == version);
    if (record == null) {
      return FormResult.fail(FormError(
        code: version == null
            ? 'template.not_found'
            : 'template.version_not_found',
        message: 'Template "$templateId"'
            '${version == null ? '' : ' version "$version"'} not found',
      ));
    }
    return FormResult.ok(FormTemplate.fromJson(record.templateJson));
  }

  @override
  Future<FormResult<List<FormTemplate>>> listTemplates({
    String? search,
    int? limit,
    int? offset,
  }) async {
    // Current version of each distinct templateId, in first-seen order.
    final seen = <String>{};
    final current = <FormTemplate>[];
    for (final id in _records.map((r) => r.templateId)) {
      if (!seen.add(id)) continue;
      final rec = _currentRecord(id)!;
      final tpl = FormTemplate.fromJson(rec.templateJson);
      if (search != null && search.isNotEmpty) {
        final q = search.toLowerCase();
        if (!tpl.name.toLowerCase().contains(q) &&
            !tpl.templateId.toLowerCase().contains(q)) {
          continue;
        }
      }
      current.add(tpl);
    }
    final start = (offset ?? 0).clamp(0, current.length);
    final end = limit == null
        ? current.length
        : (start + limit).clamp(start, current.length);
    return FormResult.ok(current.sublist(start, end));
  }

  @override
  Future<FormResult<List<FormTemplateVersion>>> getTemplateVersions({
    required String templateId,
  }) async {
    final versions = _records
        .where((r) => r.templateId == templateId)
        .map((r) => FormTemplateVersion(
              templateId: r.templateId,
              version: r.version,
              createdAt: r.createdAt,
            ))
        .toList();
    if (versions.isEmpty) {
      return FormResult.fail(FormError(
        code: 'template.not_found',
        message: 'Template "$templateId" not found',
      ));
    }
    return FormResult.ok(versions);
  }

  @override
  Future<FormResult<void>> deleteTemplate({
    required String templateId,
    String? version,
  }) async {
    final before = _records.length;
    _records.removeWhere((r) =>
        r.templateId == templateId &&
        (version == null || r.version == version));
    if (_records.length == before) {
      return FormResult.fail(FormError(
        code: 'template.not_found',
        message: 'Template "$templateId" not found',
      ));
    }
    await _store.remove(templateId, version: version);
    return FormResult.ok(null);
  }
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
