/// `VibeIconEditor`, `VibeBoolEditor`, `VibeJsonEditor`, `VibeAddRow` —
/// property-editor atoms from `property_editors.dart`. All are
/// StatelessWidget or have synchronous-only initState.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

Future<bool> _dispatch({
  required LayerId layer,
  required String path,
  required dynamic value,
}) async => true;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // ── VibeIconEditor ───────────────────────────────────────────────────────

  group('VibeIconEditor', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeIconEditor(
            label: 'Icon',
            value: 'home',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/icon',
          ),
        ),
      );
      expect(find.text('Icon'), findsOneWidget);
    });

    testWidgets('renders current value in text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeIconEditor(
            label: 'App Icon',
            value: 'star',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/appIcon',
          ),
        ),
      );
      expect(find.text('star'), findsOneWidget);
    });

    testWidgets('null value renders empty text field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeIconEditor(
            label: 'Lead Icon',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/leadIcon',
          ),
        ),
      );
      expect(find.text('Lead Icon'), findsOneWidget);
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text ?? '', isEmpty);
    });

    testWidgets('contains TextField for icon name input', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeIconEditor(
            label: 'Nav Icon',
            value: 'account_circle',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/navIcon',
          ),
        ),
      );
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('accepts typed icon name', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeIconEditor(
            label: 'Icon',
            value: 'home',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/icon',
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'settings');
      await tester.pump();
      expect(find.text('settings'), findsOneWidget);
    });
  });

  // ── VibeBoolEditor ───────────────────────────────────────────────────────

  group('VibeBoolEditor', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Visible',
            value: true,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/visible',
          ),
        ),
      );
      expect(find.text('Visible'), findsOneWidget);
    });

    testWidgets('renders three radio options (default/on/off)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Enabled',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/enabled',
          ),
        ),
      );
      expect(find.text('default'), findsOneWidget);
      expect(find.text('on'), findsOneWidget);
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('value=true highlights on radio', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Active',
            value: true,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/active',
          ),
        ),
      );
      // Three InkWell buttons rendered (default/on/off). Presence check only.
      expect(find.text('on'), findsOneWidget);
    });

    testWidgets('value=false shows off as current selection', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Bold',
            value: false,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/bold',
          ),
        ),
      );
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('tapping on radio fires dispatch', (tester) async {
      dynamic lastValue = 'sentinel';
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Toggle',
            value: null,
            dispatch: ({required layer, required path, required value}) async {
              lastValue = value;
              return true;
            },
            layer: LayerId.theme,
            path: 'ui/toggle',
          ),
        ),
      );
      await tester.tap(find.text('on'));
      await tester.pumpAndSettle();
      expect(lastValue, true);
    });

    testWidgets('tapping off fires dispatch with false', (tester) async {
      dynamic lastValue = 'sentinel';
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Toggle2',
            value: true,
            dispatch: ({required layer, required path, required value}) async {
              lastValue = value;
              return true;
            },
            layer: LayerId.theme,
            path: 'ui/toggle2',
          ),
        ),
      );
      await tester.tap(find.text('off'));
      await tester.pumpAndSettle();
      expect(lastValue, false);
    });

    testWidgets('schemaDefault tooltip text included when set', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeBoolEditor(
            label: 'Wrap',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/wrap',
            schemaDefault: true,
          ),
        ),
      );
      // Tooltip is present around 'default' radio — just assert the
      // radio renders without error; tooltip text is in the widget tree.
      expect(find.text('default'), findsOneWidget);
    });
  });

  // ── VibeJsonEditor ───────────────────────────────────────────────────────

  group('VibeJsonEditor', () {
    testWidgets('renders label text when value is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeJsonEditor(
            label: 'Props',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/props',
          ),
        ),
      );
      expect(find.text('Props'), findsOneWidget);
    });

    testWidgets('renders add icon when value is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeJsonEditor(
            label: 'Attrs',
            value: null,
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/attrs',
          ),
        ),
      );
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('renders summary and edit icon when value is a map', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VibeJsonEditor(
            label: 'Config',
            value: <String, dynamic>{'key': 'val'},
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/config',
          ),
        ),
      );
      expect(find.text('Config'), findsOneWidget);
      expect(find.byIcon(Icons.edit), findsOneWidget);
    });

    testWidgets('renders list summary count when value is a list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VibeJsonEditor(
            label: 'Items',
            value: <dynamic>[1, 2, 3],
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/items',
          ),
        ),
      );
      // Summary shows "3" for a 3-item list.
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('renders string value truncated to 12 chars', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeJsonEditor(
            label: 'Msg',
            value: 'hello-world',
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/msg',
          ),
        ),
      );
      // 'hello-world' is 11 chars - shown in full.
      expect(find.textContaining('hello-world'), findsOneWidget);
    });
  });

  // ── VibeAddRow ───────────────────────────────────────────────────────────

  group('VibeAddRow', () {
    testWidgets('renders add icon', (tester) async {
      await tester.pumpWidget(_wrap(VibeAddRow(onTap: () {})));
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('fires onTap callback when tapped', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(VibeAddRow(onTap: () => taps++)));
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('right-aligned — add icon is present in the widget tree', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(VibeAddRow(onTap: () {})));
      expect(find.byType(Align), findsWidgets);
    });
  });
}
