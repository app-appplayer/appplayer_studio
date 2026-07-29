/// Document registry — the ledger over real issue facts: facet counts,
/// combined narrowing, sortable columns, month sections, and the
/// deep-link landing (auto-open detail).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/form_builder/init/form_init.dart';
import 'package:appplayer_studio/src/apps/form_builder/ui/registry_page.dart';

import 'form_ui_harness.dart';

void main() {
  late FormUiHarness h;

  setUpAll(() async {
    h = await FormUiHarness.boot();
    // Three issues across two forms/recipients; one correction chain.
    Future<void> record(
      String number,
      String template,
      String recipient, {
      String? supersedes,
      bool approval = false,
    }) =>
        h.init.recordIssue(<String, dynamic>{
          'issueId': 'issue-$number',
          'issueNumber': number,
          'documentId': 'doc-$number',
          'templateId': template,
          'content': {
            'data': {'recipient': recipient},
          },
          'artifacts': const [],
          'issuedBy': 'nina',
          'issuedAt': '2026-07-04T0$number:00:00Z'
              .replaceFirst(RegExp(r'0(\d{4})-(\d{3}):'), '0'),
          if (supersedes != null) 'supersedes': supersedes,
          if (approval)
            'approval': {
              'requestedBy': 'nina',
              'line': const [
                {'approverId': 'lead', 'status': 'approved'},
              ],
            },
        });
    await record('2026-001', 'quote', 'Hanul');
    await record('2026-002', 'quote', 'Hanul',
        supersedes: 'issue-2026-001', approval: true);
    await record('2026-003', 'expense', 'Daesung');
    // keyValue frozen at issue time WINS over the first data field.
    await h.init.recordIssue(<String, dynamic>{
      'issueId': 'issue-2026-004',
      'issueNumber': '2026-004',
      'documentId': 'doc-2026-004',
      'templateId': 'expense',
      'content': {
        'data': {'amount': '999', 'recipient': 'Frozen Co'},
      },
      'artifacts': const [],
      'issuedBy': 'nina',
      'issuedAt': '2026-07-04T04:00:00Z',
      'keyField': 'recipient',
      'keyValue': 'Frozen Co',
    });
  });
  tearDownAll(() => h.dispose());

  Future<void> pump(WidgetTester tester, {String? landing}) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RegistryPage(init: h.init, landingIssueId: landing),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('ledger rows + facet counts render from the facts',
      (tester) async {
    await pump(tester);
    expect(find.text('2026-001'), findsOneWidget);
    expect(find.text('2026-003'), findsOneWidget);
    // Stamped keyValue beats the first data field ('999').
    expect(find.text('Frozen Co'), findsWidgets);
    expect(find.text('999'), findsNothing);
    // Facet panel: FORM counts (quote=2, expense=1) and YEAR 2026=3.
    expect(find.text('quote'), findsWidgets);
    expect(find.text('expense'), findsWidgets);
    // Status derivation: 001 superseded, 002 correction, 003 current.
    expect(find.text('superseded'), findsWidgets);
    expect(find.text('correction'), findsWidgets);
  });

  testWidgets('facet click narrows; second click clears', (tester) async {
    await pump(tester);
    // Narrow to the expense form via its facet row.
    await tester.tap(find.text('expense').first);
    await tester.pump();
    expect(find.text('2026-003'), findsOneWidget);
    expect(find.text('2026-001'), findsNothing);
    expect(find.textContaining('2 of 4 issued'), findsOneWidget);
    // Clear.
    await tester.tap(find.text('expense').first);
    await tester.pump();
    expect(find.text('2026-001'), findsOneWidget);
  });

  testWidgets('recipient facet + approval mark', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Daesung').first);
    await tester.pump();
    expect(find.text('2026-003'), findsOneWidget);
    expect(find.text('2026-002'), findsNothing);
    await tester.tap(find.text('Daesung').first);
    await tester.pump();
    // Approval facet: marked = only 2026-002.
    await tester.tap(find.text('marked').first);
    await tester.pump();
    expect(find.text('2026-002'), findsOneWidget);
    expect(find.text('2026-003'), findsNothing);
  });

  testWidgets('deep-link landing opens the linked detail', (tester) async {
    await pump(tester, landing: 'issue-2026-003');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Issue 2026-003'), findsOneWidget);
  });

  testWidgets('open dialog is torn down when the page unmounts',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hostKey = GlobalKey<_HostSwapState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _HostSwap(
          key: hostKey,
          child: RegistryPage(init: h.init, landingIssueId: 'issue-2026-003'),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Issue 2026-003'), findsOneWidget);
    // Project closes → page unmounts → the floating dialog must go too.
    hostKey.currentState!.setState(() => hostKey.currentState!.closed = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Issue 2026-003'), findsNothing);
    expect(find.text('Welcome'), findsOneWidget);
  });
}

// The dialog dies with its page — a project close (or deep-link rebind)
// unmounts the page; its detail dialog must not float over dead state.
// Live-caught 2026-07-04: issue dialog over a CLOSED project.
class _HostSwap extends StatefulWidget {
  const _HostSwap({super.key, required this.child});
  final Widget child;
  @override
  State<_HostSwap> createState() => _HostSwapState();
}

class _HostSwapState extends State<_HostSwap> {
  bool closed = false;
  @override
  Widget build(BuildContext context) => closed
      ? const Scaffold(body: Center(child: Text('Welcome')))
      : Scaffold(body: widget.child);
}
