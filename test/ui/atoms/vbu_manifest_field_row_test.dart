/// `ManifestFieldRow` — per-field control dispatcher for manifest settings.
/// Routes `toggle` / `menu` / `folder` / `text` / `number` types to atoms.
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

  testWidgets('text type renders labelled text field', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'url',
            'label': 'Server URL',
            'type': 'text',
          },
          value: 'http://localhost',
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Server URL'), findsOneWidget);
  });

  testWidgets('toggle type renders checkbox icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'enabled',
            'label': 'Enabled',
            'type': 'toggle',
          },
          value: true,
          onChanged: (_) {},
        ),
      ),
    );
    // VbuLabelledToggle uses check_box / check_box_outline_blank icons.
    expect(find.byIcon(Icons.check_box), findsOneWidget);
  });

  testWidgets('toggle fires onChanged when label is tapped', (tester) async {
    Object? result;
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'flag',
            'label': 'ToggleFlag',
            'type': 'toggle',
          },
          value: false,
          onChanged: (v) => result = v,
        ),
      ),
    );
    await tester.tap(find.text('ToggleFlag'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
  });

  testWidgets('menu type renders dropdown', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'level',
            'label': 'Log Level',
            'type': 'menu',
            'options': <String>['debug', 'info', 'warn'],
          },
          value: 'info',
          onChanged: (_) {},
        ),
      ),
    );
    // VbuLabelledMenu renders a label text
    expect(find.text('Log Level'), findsOneWidget);
  });

  testWidgets('folder type renders label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'dir',
            'label': 'Output Dir',
            'type': 'folder',
            'hint': 'Select a folder',
          },
          value: '/tmp/output',
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Output Dir'), findsOneWidget);
  });

  testWidgets('number type renders text field with label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'key': 'timeout',
            'label': 'Timeout',
            'type': 'number',
          },
          value: 30,
          onChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Timeout'), findsOneWidget);
  });

  testWidgets('missing key field falls back gracefully', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ManifestFieldRow(
          field: const <String, dynamic>{
            'label': 'Orphan Field',
            'type': 'text',
          },
          value: null,
          onChanged: (_) {},
        ),
      ),
    );
    // Should not throw; renders something
    expect(find.byType(ManifestFieldRow), findsOneWidget);
  });
}
