import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appplayer_studio/src/apps/form_builder/init/form_init.dart';
import 'package:appplayer_studio/src/apps/form_builder/ui/issues_page.dart';

// The issued-document management surface: list badges, current-only filter,
// the AS-ISSUED document view (frozen markdown artifact), and the
// correct-&-reissue handoff.
void main() {
  late Directory projectRoot;
  late FormInit init;

  Future<void> record(
    String n, {
    String? supersedes,
    bool withMd = false,
  }) async {
    final artifacts = <Map<String, dynamic>>[
      {'format': 'pdf', 'locator': 'forms/2026-$n/document.pdf'},
      if (withMd)
        {'format': 'markdown', 'locator': 'forms/2026-$n/document.md'},
    ];
    if (withMd) {
      final f = File(
        '${projectRoot.path}/forms/2026-$n/document.md',
      );
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('# Quotation\n\nrecipient: To Hanul Trading ($n)');
    }
    await init.recordIssue({
      'issueId': 'issue-2026-$n',
      'issueNumber': '2026-$n',
      'documentId': 'doc-$n',
      'templateId': 'quote-kr',
      'templateVersion': '1.0.0',
      'content': {
        'templateId': 'quote-kr',
        'data': {'recipient': 'To Hanul Trading', 'round': n},
      },
      'artifacts': artifacts,
      'issuedAt': '2026-07-03T0$n:00:00Z',
      if (supersedes != null) 'supersedes': supersedes,
    });
  }

  setUp(() async {
    projectRoot = await Directory.systemTemp.createTemp('issues_widget_');
  });

  tearDown(() async {
    if (await projectRoot.exists()) {
      await projectRoot.delete(recursive: true);
    }
  });

  /// The page loads issues through REAL file IO (FactGraph on disk), which
  /// never completes inside flutter_test's FakeAsync zone — flush it with
  /// [WidgetTester.runAsync] instead of pumpAndSettle (which would spin on
  /// the loading indicator forever).
  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pump(WidgetTester tester, {List<String>? corrected}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IssuesPage(
            init: init,
            onCorrect: (issue) => corrected?.add(issue['issueId'] as String),
          ),
        ),
      ),
    );
    await settleIo(tester);
  }

  testWidgets(
    'superseded badge + current-only filter hide replaced snapshots',
    (tester) async {
      await tester.runAsync(() async {
        init = await FormInit.boot(projectRoot.path, 'proj-w');
        await record('001');
        await record('002', supersedes: 'issue-2026-001');
      });
      await pump(tester);

      expect(find.textContaining('2026-001'), findsWidgets);
      expect(find.text('superseded'), findsOneWidget);

      await tester.tap(find.text('current only'));
      await tester.pump();
      expect(find.text('superseded'), findsNothing);
      expect(find.textContaining('2026-002'), findsWidgets);
    },
  );

  testWidgets(
    'tap opens the as-issued document view (frozen markdown) and '
    'correct-&-reissue hands the issue to the shell',
    (tester) async {
      final corrected = <String>[];
      await tester.runAsync(() async {
        init = await FormInit.boot(projectRoot.path, 'proj-w');
        await record('001', withMd: true);
      });
      await pump(tester, corrected: corrected);

      await tester.tap(find.textContaining('2026-001').first);
      await settleIo(tester);

      expect(find.textContaining('Issue 2026-001'), findsOneWidget);
      // Frozen markdown made it into the viewer (rendered heading text).
      expect(find.textContaining('Quotation'), findsWidgets);
      expect(find.text('open folder'), findsOneWidget);

      await tester.tap(find.text('Correct & reissue'));
      await tester.pump();
      expect(corrected, ['issue-2026-001']);
      // Dialog closed by the handoff (pop transition needs a few frames).
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Correct & reissue'), findsNothing);
    },
  );

  testWidgets('search narrows by number/content', (tester) async {
    await tester.runAsync(() async {
      init = await FormInit.boot(projectRoot.path, 'proj-w');
      await record('001', withMd: true);
      await record('002');
    });
    await pump(tester);

    await tester.enterText(find.byType(TextField), '2026-002');
    await tester.pump();
    expect(find.textContaining('2026-002'), findsWidgets);
    expect(find.textContaining('2026-001'), findsNothing);
  });
}
