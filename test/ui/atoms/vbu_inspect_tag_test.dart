/// `inspectTag` — wraps a child in `MetaData` with type/id/label/text/title
/// and extra fields so the studio's element resolver can address it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('child renders unchanged', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(
          type: 'sub_tab',
          child: const Text('hello', key: Key('child')),
        ),
      ),
    );
    expect(find.byKey(const Key('child')), findsOneWidget);
  });

  testWidgets('MetaData has type field', (tester) async {
    await tester.pumpWidget(
      _wrap(inspectTag(type: 'dialog_action', child: const SizedBox())),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['type'], 'dialog_action');
  });

  testWidgets('id field included when provided', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(type: 'list_row', id: 'row-42', child: const SizedBox()),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['id'], 'row-42');
  });

  testWidgets('label field included when non-empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(
          type: 'dialog_action',
          label: 'Save',
          child: const SizedBox(),
        ),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['label'], 'Save');
  });

  testWidgets('text field included when non-empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(type: 'chip', text: 'pill-text', child: const SizedBox()),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['text'], 'pill-text');
  });

  testWidgets('title field included when non-empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(
          type: 'section',
          title: 'My Section',
          child: const SizedBox(),
        ),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['title'], 'My Section');
  });

  testWidgets('extra fields are merged without overwriting type', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(
          type: 'list_row',
          extra: const <String, dynamic>{'source': 'manifest', 'count': 3},
          child: const SizedBox(),
        ),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m['type'], 'list_row');
    expect(m['source'], 'manifest');
    expect(m['count'], 3);
  });

  testWidgets('null / empty optional fields are omitted from meta', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(type: 'item', id: '', label: null, child: const SizedBox()),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    final m = meta.metaData as Map<String, dynamic>;
    expect(m.containsKey('id'), isFalse);
    expect(m.containsKey('label'), isFalse);
  });

  testWidgets('behavior is HitTestBehavior.translucent', (tester) async {
    await tester.pumpWidget(
      _wrap(
        inspectTag(
          type: 'hit_test_check',
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );
    final meta = tester.widget<MetaData>(find.byType(MetaData).first);
    expect(meta.behavior, HitTestBehavior.translucent);
  });
}
