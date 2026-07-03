import 'dart:convert' show base64Decode, jsonDecode;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:appplayer_studio/src/apps/form_builder/ui/compose_page.dart';

import 'form_ui_harness.dart';

// The Compose UI matrix against the REAL tool surface: picking a template
// builds the visual editors, typing lands on the sheet, table rows
// add/remove/edit, and Validate / Save draft / Issue drive the real
// engine + fact pipeline (files frozen under forms/<n>/).
void main() {
  late FormUiHarness h;

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() async {
    h = await FormUiHarness.boot();
    await h.server.callTool('form.save_template', {
      'template': harnessTemplate(),
    });
  });
  tearDown(() => h.dispose());

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    Map<String, dynamic>? correction,
  }) async {
    tester.view.physicalSize = const Size(2200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComposePage(
            server: h.server,
            init: h.init,
            correction: correction,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> pickHarnessTemplate(WidgetTester tester) async {
    await tester.tap(find.text('Pick template'));
    await settle(tester, 4);
    await tester.tap(find.text('Harness Quote · harness-quote'));
    await settle(tester);
  }

  testWidgets('pick template builds field + table editors and the sheet', (
    tester,
  ) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    expect(find.text('FIELDS'), findsOneWidget);
    expect(find.text('TABLE · ITEMS'), findsOneWidget);
    // Sheet shows the placeholder field + template's default row.
    expect(find.text('《수신》'), findsOneWidget);
    expect(find.text('기본품목'), findsWidgets);
  });

  testWidgets('typing into a field re-renders the sheet', (tester) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '수신'),
      '대성전자 귀중',
    );
    await tester.pump();
    // Placeholder replaced by the typed value on the sheet.
    expect(find.text('《수신》'), findsNothing);
    expect(find.text('대성전자 귀중'), findsWidgets);
  });

  testWidgets('add row + edit cell shows on the sheet; remove row works', (
    tester,
  ) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    await tester.tap(find.text('Add row'));
    await tester.pump();
    expect(find.text('row 2'), findsOneWidget);
    // Type into the new row's 품목 cell (second table-editor row).
    await tester.enterText(
      find.widgetWithText(TextField, '품목').last,
      '추가품목',
    );
    await tester.pump();
    expect(find.text('추가품목'), findsWidgets); // editor + sheet
    // Remove row 2 (its close icon).
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('row 2'),
          matching: find.byType(Container),
        ),
        matching: find.byIcon(Icons.close),
      ).first,
    );
    await tester.pump();
    expect(find.text('row 2'), findsNothing);
  });

  testWidgets('Validate reports a clean document', (tester) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '수신'),
      '대성전자',
    );
    await tester.tap(find.text('Validate'));
    await settle(tester);
    expect(find.textContaining('Valid — no issues'), findsOneWidget);
  });

  testWidgets('Save draft persists data AND table rows; load restores', (
    tester,
  ) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '수신'),
      '한울정공',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '품목').first,
      '드래프트품목',
    );
    await tester.pump();
    await tester.tap(find.text('Save draft'));
    await settle(tester, 12);
    final drafts = await tester.runAsync(() => h.init.listDrafts());
    expect(drafts, hasLength(1));
    final doc =
        (drafts!.first['document'] as Map).cast<String, dynamic>();
    expect(doc['data']?['수신'], '한울정공');
    final tables = (doc['tables'] as Map).cast<String, dynamic>();
    expect(
      ((tables['items'] as List).first as Map)['name'],
      '드래프트품목',
    );
    // Fresh page → load the draft from the list → editors restored.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await pumpPage(tester);
    await tester.tap(find.textContaining('harness-quote').first);
    await settle(tester, 12);
    expect(find.text('한울정공'), findsWidgets);
    expect(find.text('드래프트품목'), findsWidgets);
  });

  testWidgets('Issue freezes artifacts on disk and records the issue', (
    tester,
  ) async {
    await pumpPage(tester);
    await pickHarnessTemplate(tester);
    await tester.enterText(
      find.widgetWithText(TextField, '수신'),
      '발행대상',
    );
    await tester.pump();
    // Select HTML and IMAGE in addition to the default PDF — exactly the
    // checked media must land on disk, nothing else.
    await tester.tap(find.widgetWithText(FilterChip, 'html'));
    await tester.tap(find.widgetWithText(FilterChip, 'image'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Issue'));
    // The issue pipeline renders the chosen media + the record to disk —
    // give the real IO time.
    await settle(tester, 60);
    expect(find.textContaining('Issued'), findsOneWidget);
    final issues = await tester.runAsync(() => h.init.listIssues());
    expect(issues, hasLength(1));
    final number = issues!.first['issueNumber'] as String;
    final dir = Directory('${h.projectRoot.path}/forms/$number');
    final files = await tester.runAsync(
      () async => dir.list().map((f) => f.path.split('/').last).toList(),
    );
    expect(
      files,
      containsAll(
        [
          'document.pdf',
          'document.html',
          'document.png',
          'document.formdoc.json',
        ],
      ),
    );
    expect(files, isNot(contains('document.md')));
    // The image artifact is a real PNG raster.
    final pngHead = await tester.runAsync(
      () async => (await File('${dir.path}/document.png').open())
          .read(8),
    );
    expect(
      pngHead,
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    );
    // The frozen data is the typed value.
    final content =
        (issues.first['content'] as Map).cast<String, dynamic>();
    expect(content['data']?['수신'], '발행대상');
  });

  testWidgets(
    'issued formdoc keeps image placement/size and patch-true table rows; '
    'local image is copied next to the artifacts',
    (tester) async {
      // Template with a PLACED image (the styles the uiDsl freeze loses).
      final tpl = harnessTemplate(id: 'placed-quote');
      final img = File('${h.projectRoot.path}/stamp.png');
      img.writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ));
      ((tpl['defaultSections'] as List).first['blocks'] as List).add({
        'blockId': 'seal',
        'type': 'image',
        'index': 3,
        'src': 'stamp.png',
        'maxWidth': 90,
        'style': {
          'placement': {'anchor': 'bottom-left', 'x': 20, 'y': 20},
        },
      });
      await tester.runAsync(
        () => h.server.callTool('form.save_template', {'template': tpl}),
      );
      await pumpPage(tester);
      await tester.tap(find.text('Pick template'));
      await settle(tester, 4);
      await tester.tap(find.text('Harness Quote · placed-quote'));
      await settle(tester);
      // Edit the table so the snapshot must carry PATCHED rows.
      await tester.enterText(
        find.widgetWithText(TextField, '품목').first,
        '패치품목',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Issue'));
      await settle(tester, 60);
      final issues = await tester.runAsync(() => h.init.listIssues());
      final number = issues!.first['issueNumber'] as String;
      final dir = '${h.projectRoot.path}/forms/$number';
      // 0) default selection = pdf only; the RECORD is still frozen and
      // no unselected media leak in.
      expect(File('$dir/document.html').existsSync(), isFalse);
      expect(File('$dir/document.png').existsSync(), isFalse);
      // 1) typed snapshot exists and keeps the image's placement + size.
      final snap = await tester.runAsync(() async {
        return jsonDecode(
          await File('$dir/document.formdoc.json').readAsString(),
        ) as Map;
      });
      final blocks = ((snap!['sections'] as List).first
          as Map)['blocks'] as List;
      final seal =
          blocks.cast<Map>().firstWhere((b) => b['blockId'] == 'seal');
      expect(seal['maxWidth'], 90);
      expect(seal['style']?['placement']?['anchor'], 'bottom-left');
      // 2) table rows are the PATCHED (composed) content, not the template
      // example.
      final items =
          blocks.cast<Map>().firstWhere((b) => b['blockId'] == 'items');
      expect(
        ((items['rows'] as List).first as Map)['cells']?['name'],
        '패치품목',
      );
      // 3) the local image was copied next to the artifacts (HTML <img>
      // relative src resolves).
      expect(File('$dir/stamp.png').existsSync(), isTrue);
    },
  );
}
