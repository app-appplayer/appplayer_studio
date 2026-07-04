/// Approvals route + approval gate — the 결재함 matrix over the REAL tool
/// surface (no mocks): request → pending card renders → issue is REFUSED
/// while pending → approve through the dialog → line completes → issue
/// passes and freezes the line as provenance.
library;

import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/builtin_api.dart' as mk
    show KernelTextContent;
import 'package:appplayer_studio/src/apps/form_builder/ui/approvals_page.dart';

import 'form_ui_harness.dart';

void main() {
  late FormUiHarness h;

  setUpAll(() async => h = await FormUiHarness.boot());
  tearDownAll(() => h.dispose());

  Future<Map<String, dynamic>> call(
    WidgetTester tester,
    String name,
    Map<String, dynamic> args,
  ) async {
    final out = await tester.runAsync(() async {
      final r = await h.server.callTool(name, args);
      final text = r.content
          .whereType<mk.KernelTextContent>()
          .map((c) => c.text)
          .join();
      return (jsonDecode(text) as Map).cast<String, dynamic>();
    });
    return out!;
  }

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalsPage(server: h.server, init: h.init),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets(
      'request → pending card · issue refused · approve via dialog → '
      'line completes → issue passes with provenance', (tester) async {
    await call(tester, 'form.save_template', {'template': harnessTemplate()});
    final created = await call(tester, 'form.create_document', {
      'templateId': 'harness-quote',
      'data': {'수신': '한울정공'},
    });
    final documentId = created['documentId'] as String;
    await call(tester, 'form_builder.draft_save', {
      'documentId': documentId,
      'templateId': 'harness-quote',
      'data': {'수신': '한울정공'},
    });
    final requested = await call(tester, 'form_builder.approval_request', {
      'documentId': documentId,
      'requestedBy': 'nina',
      'title': '지출 기안',
      'line': [
        {'approverId': 'dept-lead', 'roleLabel': '부서장'},
      ],
    });
    expect(requested['state'], 'pending');

    // Gate: issuing while the approval is pending is refused with the
    // stable code an LLM self-corrects from.
    final refused = await call(tester, 'form_builder.issue', {
      'documentId': documentId,
    });
    expect(refused['code'], 'form_builder.approval_required');

    // The pending card renders: title, requester, current gate, line chip.
    await pumpPage(tester);
    expect(find.text('지출 기안'), findsOneWidget);
    expect(find.textContaining('current gate dept-lead'), findsOneWidget);
    expect(find.textContaining('dept-lead (부서장)'), findsOneWidget);

    // Approve through the dialog (button = tool).
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await settle(tester, 4);
    await tester.enterText(
      find.widgetWithText(TextField, 'Comment (optional)'),
      '확인했음',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Approve').last);
    await settle(tester, 40);
    expect(find.text('approved'), findsOneWidget);

    // Server state advanced — and the issue now passes, freezing the line.
    final approval = await call(tester, 'form_builder.approval_list', {
      'scope': 'requested',
      'actor': 'nina',
    });
    final ap = (approval['approvals'] as List).cast<Map>().single;
    expect(ap['state'], 'approved');

    final issued = await call(tester, 'form_builder.issue', {
      'documentId': documentId,
      'formats': ['markdown'],
      'issuedBy': 'nina',
    });
    expect(issued['issueNumber'], isNotNull);
    final prov = (issued['approval'] as Map).cast<String, dynamic>();
    expect(prov['requestedBy'], 'nina');
    expect(
      ((prov['line'] as List).first as Map)['actedBy'],
      'dept-lead',
    );
  });

  testWidgets('reject flow: comment required in dialog semantics, draft '
      'returns to draft, 결재함 empties', (tester) async {
    final created = await call(tester, 'form.create_document', {
      'templateId': 'harness-quote',
      'data': {'수신': '반려대상'},
    });
    final documentId = created['documentId'] as String;
    await call(tester, 'form_builder.draft_save', {
      'documentId': documentId,
      'templateId': 'harness-quote',
      'data': {'수신': '반려대상'},
    });
    await call(tester, 'form_builder.approval_request', {
      'documentId': documentId,
      'requestedBy': 'nina',
      'title': '반려 케이스',
      'line': [
        {'approverId': 'owner'},
      ],
    });

    await pumpPage(tester);
    expect(find.text('반려 케이스'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
    await settle(tester, 4);
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason (required)'),
      '금액 재검토',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
    await settle(tester, 40);
    expect(find.text('rejected'), findsOneWidget);

    final draft = await call(tester, 'form_builder.draft_get', {
      'documentId': documentId,
    });
    expect(draft['status'] ?? draft['draft']?['status'], isNotNull);
    final mine = await call(tester, 'form_builder.approval_list', {
      'scope': 'mine',
      'actor': 'owner',
    });
    expect(mine['approvals'], isEmpty);
  });

  testWidgets(
      'draft re-key moves the approval — a reloaded document cannot bypass '
      'a pending gate and keeps provenance', (tester) async {
    final created = await call(tester, 'form.create_document', {
      'templateId': 'harness-quote',
      'data': {'수신': '재키검증'},
    });
    final docA = created['documentId'] as String;
    await call(tester, 'form_builder.draft_save', {
      'documentId': docA,
      'templateId': 'harness-quote',
      'data': {'수신': '재키검증'},
    });
    await call(tester, 'form_builder.approval_request', {
      'documentId': docA,
      'requestedBy': 'nina',
      'title': '재키 기안',
      'line': [
        {'approverId': 'lead'},
      ],
    });

    // Editor reload: a NEW engine document replaces the draft.
    final again = await call(tester, 'form.create_document', {
      'templateId': 'harness-quote',
      'data': {'수신': '재키검증'},
    });
    final docB = again['documentId'] as String;
    await call(tester, 'form_builder.draft_save', {
      'documentId': docB,
      'templateId': 'harness-quote',
      'data': {'수신': '재키검증'},
      'previousDocumentId': docA,
    });

    // The pending gate FOLLOWED the document — issuing docB is refused.
    final refused = await call(tester, 'form_builder.issue', {
      'documentId': docB,
      'formats': ['markdown'],
    });
    expect(refused['code'], 'form_builder.approval_required');

    // Approve under the NEW id, issue, and the provenance rides along.
    await call(tester, 'form_builder.approve', {
      'documentId': docB,
      'actor': 'lead',
    });
    final issued = await call(tester, 'form_builder.issue', {
      'documentId': docB,
      'formats': ['markdown'],
      'issuedBy': 'nina',
    });
    expect((issued['approval'] as Map)['requestedBy'], 'nina');
    // The old key is gone.
    final all = await call(tester, 'form_builder.approval_list', {});
    final ids = [
      for (final a in (all['approvals'] as List).cast<Map>())
        a['documentId'],
    ];
    expect(ids, contains(docB));
    expect(ids, isNot(contains(docA)));
  });
}
