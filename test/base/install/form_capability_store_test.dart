import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    show
        FormFontPolicy,
        FormLayoutPolicy,
        FormMargins,
        FormPageSize,
        FormSchema,
        FormSchemaField,
        FormTemplate;
import 'package:mcp_knowledge/mcp_knowledge.dart' show KnowledgeSystem;

import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show FactBackedFormTemplatePort, FormTemplateRecord;
import 'package:appplayer_studio/src/base/install/form_capability_store.dart';
import 'package:appplayer_studio/src/base/install/knowledge_persistence/knowledge_persistence.dart'
    show assemblePersistentKnowledgeSystem;

// The kernel binding under test: template versions persist as
// `form_template` facts in a per-project (disk-backed) FactGraph, in save
// order, surviving a full system re-assembly (= app restart).
void main() {
  late Directory projectRoot;

  Future<KnowledgeSystem> boot() => assemblePersistentKnowledgeSystem(
    projectRoot: projectRoot.path,
    projectId: 'proj-a',
  );

  KernelFormTemplateFactStore storeOf(KnowledgeSystem system) =>
      KernelFormTemplateFactStore(facts: system.facts, workspaceId: 'proj-a');

  FormTemplateRecord record(String id, String version, {DateTime? at}) =>
      FormTemplateRecord(
        templateId: id,
        version: version,
        createdAt: at ?? DateTime(2026, 7, 3, 12),
        templateJson: template(id, version).toJson(),
      );

  setUp(() async {
    projectRoot = await Directory.systemTemp.createTemp('form_store_test');
  });

  tearDown(() async {
    if (await projectRoot.exists()) {
      await projectRoot.delete(recursive: true);
    }
  });

  test('append/loadAll round-trips records in save order', () async {
    final store = storeOf(await boot());
    // Same createdAt on purpose — order must come from the store, not the
    // timestamp.
    final at = DateTime(2026, 7, 3, 12);
    await store.append(record('quote', '1.0.0', at: at));
    await store.append(record('quote', '1.1.0', at: at));
    await store.append(record('resume', '1.0.0', at: at));

    final all = await store.loadAll();
    expect(
      all.map((r) => '${r.templateId}@${r.version}').toList(),
      ['quote@1.0.0', 'quote@1.1.0', 'resume@1.0.0'],
    );
    expect(all.first.templateJson['templateId'], 'quote');
    // The store-level ordering key must not leak into the recipe payload.
    expect(all.first.templateJson.containsKey('seq'), isFalse);
  });

  test('records survive a system re-assembly (restart)', () async {
    final at = DateTime(2026, 7, 1, 9, 30);
    await storeOf(await boot()).append(record('quote', '1.0.0', at: at));

    // Fresh assembly over the same project root = app restart.
    final reloaded = await storeOf(await boot()).loadAll();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.templateId, 'quote');
    // The version's issuance time is preserved, not re-stamped at hydrate.
    expect(reloaded.single.createdAt, at);
  });

  test('remove drops one version or a whole template', () async {
    final store = storeOf(await boot());
    await store.append(record('quote', '1.0.0'));
    await store.append(record('quote', '1.1.0'));
    await store.append(record('resume', '1.0.0'));

    await store.remove('quote', version: '1.0.0');
    expect(
      (await store.loadAll()).map((r) => '${r.templateId}@${r.version}'),
      ['quote@1.1.0', 'resume@1.0.0'],
    );

    await store.remove('quote');
    expect(
      (await store.loadAll()).map((r) => r.templateId),
      ['resume'],
    );
  });

  test('seq keeps advancing across restarts (no order collision)', () async {
    final at = DateTime(2026, 7, 3, 12);
    await storeOf(await boot()).append(record('quote', '1.0.0', at: at));
    final store2 = storeOf(await boot());
    await store2.append(record('quote', '1.1.0', at: at));

    final all = await store2.loadAll();
    expect(
      all.map((r) => r.version).toList(),
      ['1.0.0', '1.1.0'],
      reason: 'the second boot must append AFTER the persisted max seq',
    );
  });

  test(
    'FactBackedFormTemplatePort over the kernel store: save · current-version '
    'list · duplicate rejection · restart hydration',
    () async {
      final port = await FactBackedFormTemplatePort.hydrate(
        storeOf(await boot()),
      );

      final v1 = await port.saveTemplate(template: template('quote', '1.0.0'));
      expect(v1.success, isTrue);
      final v2 = await port.saveTemplate(template: template('quote', '1.1.0'));
      expect(v2.success, isTrue);

      final dup = await port.saveTemplate(template: template('quote', '1.1.0'));
      expect(dup.success, isFalse);
      expect(dup.error?.code, 'template.duplicate');

      final list = await port.listTemplates();
      expect(list.data!.single.version, '1.1.0', reason: 'last save = current');

      // Restart: a fresh port over a fresh system sees the same templates.
      final rePort = await FactBackedFormTemplatePort.hydrate(
        storeOf(await boot()),
      );
      final versions = await rePort.getTemplateVersions(templateId: 'quote');
      expect(versions.data!.map((v) => v.version), ['1.0.0', '1.1.0']);
    },
  );
}

FormTemplate template(String id, String version) => FormTemplate(
  templateId: id,
  version: version,
  name: 'Template $id',
  schema: FormSchema(fields: [FormSchemaField(name: 'title', type: 'string')]),
  layoutPolicy: const FormLayoutPolicy(
    pageSize: FormPageSize(size: 'A4', width: 210, height: 297),
    margins: FormMargins(top: 20, right: 20, bottom: 20, left: 20),
    fontPolicy: FormFontPolicy(
      defaultFont: 'sans-serif',
      defaultSize: 12,
      headingSize: 18,
      bodySize: 12,
      minSize: 8,
    ),
  ),
);
