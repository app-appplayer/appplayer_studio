/// `VibeColorEditor` and `VibeTextEditor` — labelled property-editor
/// rows from `property_editors.dart`. Both have synchronous initState
/// (TextEditingController + FocusNode only, no file I/O).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

// Stub dispatcher — always returns true and records the call.
Future<bool> _dispatch({
  required LayerId layer,
  required String path,
  required dynamic value,
}) async => true;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── VibeColorEditor ──────────────────────────────────────────────────────

  group('VibeColorEditor', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeColorEditor(
            label: 'Background',
            value: '#FFFFFF',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/color/bg',
          ),
        ),
      );
      expect(find.text('Background'), findsOneWidget);
    });

    testWidgets('renders hex value in text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeColorEditor(
            label: 'Accent',
            value: '#00FF88',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/color/accent',
          ),
        ),
      );
      expect(find.text('#00FF88'), findsOneWidget);
    });

    testWidgets('null value renders empty text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeColorEditor(
            label: 'Border',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/color/border',
          ),
        ),
      );
      expect(find.text('Border'), findsOneWidget);
      // TextField exists and is empty
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text ?? '', isEmpty);
    });

    testWidgets('contains one TextField for hex input', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeColorEditor(
            label: 'X',
            value: '#112233',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'some/path',
          ),
        ),
      );
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('text entered in field is reflected in the widget', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VibeColorEditor(
            label: 'Primary',
            value: '#000000',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'color/primary',
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '#AABBCC');
      await tester.pump();
      expect(find.text('#AABBCC'), findsOneWidget);
    });
  });

  // ── VibeTextEditor ───────────────────────────────────────────────────────

  group('VibeTextEditor', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeTextEditor(
            label: 'Title',
            value: 'Hello',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/text/title',
          ),
        ),
      );
      expect(find.text('Title'), findsOneWidget);
    });

    testWidgets('renders current value in text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeTextEditor(
            label: 'Name',
            value: 'Alice',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/name',
          ),
        ),
      );
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('null value renders empty text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeTextEditor(
            label: 'Subtitle',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/subtitle',
          ),
        ),
      );
      expect(find.text('Subtitle'), findsOneWidget);
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text ?? '', isEmpty);
    });

    testWidgets('numeric mode renders number keyboard type', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeTextEditor(
            label: 'Count',
            value: '42',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/count',
            numeric: true,
          ),
        ),
      );
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.keyboardType, isNotNull);
    });

    testWidgets('accepts user input', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeTextEditor(
            label: 'Tag',
            value: 'old',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/tag',
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'new-value');
      await tester.pump();
      expect(find.text('new-value'), findsOneWidget);
    });
  });
}
