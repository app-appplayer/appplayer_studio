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

  test('approval line: request → 2-step approve → completes, draft status '
      'tracks review→approved', () async {
    final init = await boot();
    await init.saveDraft(
      documentId: 'doc-a',
      document: {'templateId': 'quote', 'data': {}},
      status: 'draft',
    );
    await init.requestApproval(
      documentId: 'doc-a',
      requestedBy: 'nina',
      title: '지출 기안',
      line: [
        {'approverId': 'dept-lead', 'roleLabel': '부서장'},
        {'approverId': 'owner', 'roleLabel': '오너'},
      ],
    );
    expect((await init.getDraft('doc-a'))!['status'], 'review');

    // Wrong actor at the first gate is refused.
    await expectLater(
      init.approve(documentId: 'doc-a', actor: 'owner'),
      throwsA(isA<FormApprovalError>()),
    );

    var a = await init.approve(
        documentId: 'doc-a', actor: 'dept-lead', comment: 'OK');
    expect(a['state'], 'pending');
    expect(a['currentIndex'], 1);

    a = await init.approve(documentId: 'doc-a', actor: 'owner');
    expect(a['state'], 'approved');
    final line = (a['line'] as List).cast<Map>();
    expect(line[0]['actedBy'], 'dept-lead');
    expect(line[0]['comment'], 'OK');
    expect((await init.getDraft('doc-a'))!['status'], 'approved');
  });

  test('전결(finalize) skips the rest; reject needs a reason and resets '
      'the draft; re-request replaces', () async {
    final init = await boot();
    await init.saveDraft(
      documentId: 'doc-b',
      document: {'templateId': 'quote', 'data': {}},
      status: 'draft',
    );
    Future<void> request() => init.requestApproval(
          documentId: 'doc-b',
          requestedBy: 'nina',
          line: [
            {'approverId': 'lead'},
            {'approverId': 'director'},
            {'approverId': 'owner'},
          ],
        );

    // 전결 at the first gate completes the whole line.
    await request();
    var a = await init.approve(
        documentId: 'doc-b', actor: 'lead', finalize: true);
    expect(a['state'], 'approved');
    expect(
      (a['line'] as List).cast<Map>().map((e) => e['status']).toList(),
      ['approved', 'skipped', 'skipped'],
    );

    // Re-request (재상신) replaces; a reject without a reason is refused.
    await request();
    await expectLater(
      init.reject(documentId: 'doc-b', actor: 'lead', comment: '  '),
      throwsA(isA<FormApprovalError>()),
    );
    a = await init.reject(
        documentId: 'doc-b', actor: 'lead', comment: '금액 재검토');
    expect(a['state'], 'rejected');
    expect((await init.getDraft('doc-b'))!['status'], 'draft');

    // Acting on a rejected approval is refused; withdraw needs a pending one.
    await expectLater(
      init.approve(documentId: 'doc-b', actor: 'lead'),
      throwsA(isA<FormApprovalError>()),
    );

    // Withdraw path: only the requester may.
    await request();
    await expectLater(
      init.withdrawApproval(documentId: 'doc-b', actor: 'lead'),
      throwsA(isA<FormApprovalError>()),
    );
    a = await init.withdrawApproval(documentId: 'doc-b', actor: 'nina');
    expect(a['state'], 'withdrawn');
  });

  test('approval survives a restart (fact-backed)', () async {
    final init = await boot();
    await init.saveDraft(
      documentId: 'doc-c',
      document: {'templateId': 'quote', 'data': {}},
      status: 'draft',
    );
    await init.requestApproval(
      documentId: 'doc-c',
      requestedBy: 'nina',
      line: [
        {'approverId': 'lead'},
      ],
    );
    final reborn = await boot();
    final a = await reborn.getApproval('doc-c');
    expect(a, isNotNull);
    expect(a!['state'], 'pending');
    expect(await reborn.listApprovals(), hasLength(1));
  });
}
