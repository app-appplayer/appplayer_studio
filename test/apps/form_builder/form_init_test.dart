import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:appplayer_studio/src/apps/form_builder/init/form_init.dart';

// FormInit's fact wiring: drafts (replace-on-resave — the facade REJECTS a
// duplicate factId, so a re-save must delete-then-write; live-caught
// 2026-07-03), issue records + numbering, and restart survival.
void main() {
  late Directory projectRoot;

  Future<FormInit> boot() => FormInit.boot(projectRoot.path, 'proj-t');

  setUp(() async {
    projectRoot = await Directory.systemTemp.createTemp('form_init_test');
  });

  tearDown(() async {
    if (await projectRoot.exists()) {
      await projectRoot.delete(recursive: true);
    }
  });

  test('draft re-save replaces (no FactConflictException), latest wins',
      () async {
    final init = await boot();
    await init.saveDraft(
      documentId: 'doc-1',
      document: {'templateId': 'quote', 'data': {'title': 'a'}},
      status: 'draft',
    );
    // The regression: second save on the SAME documentId must not throw.
    await init.saveDraft(
      documentId: 'doc-1',
      document: {'templateId': 'quote', 'data': {'title': 'b'}},
      status: 'published',
    );

    final drafts = await init.listDrafts();
    expect(drafts, hasLength(1));
    expect(drafts.single['status'], 'published');
    expect((drafts.single['document'] as Map)['data'], {'title': 'b'});
  });

  test('issue numbering is per-year sequential and survives a restart',
      () async {
    final init = await boot();
    final year = DateTime.now().toUtc().year;
    final n1 = await init.nextIssueNumber();
    expect(n1, '$year-001');
    await init.recordIssue({
      'issueId': 'issue-$n1',
      'issueNumber': n1,
      'documentId': 'doc-1',
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
    });

    // Restart: numbering derives from persisted issue facts, not memory.
    final reborn = await boot();
    expect(await reborn.nextIssueNumber(), '$year-002');
    final issues = await reborn.listIssues();
    expect(issues.single['issueNumber'], n1);
    expect(await reborn.getIssue('issue-$n1'), isNotNull);
  });

  test('drafts survive a restart; deleteDraft removes', () async {
    final init = await boot();
    await init.saveDraft(
      documentId: 'doc-9',
      document: {'templateId': 'quote', 'data': {}},
      status: 'draft',
    );
    final reborn = await boot();
    expect((await reborn.listDrafts()).single['documentId'], 'doc-9');
    await reborn.deleteDraft('doc-9');
    expect(await reborn.listDrafts(), isEmpty);
  });
}
