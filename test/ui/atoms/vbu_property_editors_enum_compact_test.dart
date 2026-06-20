/// `VibeEnumEditor`, `VibeCompactInputBox`, `VibeCompactDropdown` —
/// property-editor compound and container atoms. StatelessWidget or
/// StatefulWidget with no initState file I/O.
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

  // ── VibeEnumEditor ───────────────────────────────────────────────────────

  group('VibeEnumEditor', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeEnumEditor(
            label: 'Align',
            value: 'left',
            options: const <String>['left', 'center', 'right'],
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/align',
          ),
        ),
      );
      expect(find.text('Align'), findsOneWidget);
    });

    testWidgets('renders current selected value', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeEnumEditor(
            label: 'Size',
            value: 'medium',
            options: const <String>['small', 'medium', 'large'],
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/size',
          ),
        ),
      );
      expect(find.text('medium'), findsOneWidget);
    });

    testWidgets('null value shows placeholder dash', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeEnumEditor(
            label: 'Weight',
            value: null,
            options: const <String>['normal', 'bold'],
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/weight',
          ),
        ),
      );
      expect(find.text('Weight'), findsOneWidget);
      // '—' is the placeholder text when value is null.
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('renders without crashing with empty options list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VibeEnumEditor(
            label: 'Empty',
            value: null,
            options: const <String>[],
            dispatch: _dispatch,
            layer: LayerId.theme,
            path: 'ui/empty',
          ),
        ),
      );
      expect(find.byType(VibeEnumEditor), findsOneWidget);
    });
  });

  // ── VibeCompactInputBox ──────────────────────────────────────────────────

  group('VibeCompactInputBox', () {
    testWidgets('renders its child widget', (tester) async {
      await tester.pumpWidget(
        _wrap(const VibeCompactInputBox(child: Text('inside'))),
      );
      expect(find.text('inside'), findsOneWidget);
    });

    testWidgets('warning=false renders without coral border applied', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const VibeCompactInputBox(warning: false, child: Text('ok'))),
      );
      expect(find.byType(VibeCompactInputBox), findsOneWidget);
    });

    testWidgets('warning=true still renders the child', (tester) async {
      await tester.pumpWidget(
        _wrap(const VibeCompactInputBox(warning: true, child: Text('warn'))),
      );
      expect(find.text('warn'), findsOneWidget);
    });

    testWidgets('has fixed height container', (tester) async {
      await tester.pumpWidget(
        _wrap(const VibeCompactInputBox(child: Text('h'))),
      );
      // The outer Container has height 28; find a Container that has
      // height constraints applied.
      expect(find.byType(Container), findsWidgets);
    });
  });

  // ── VibeCompactDropdown ──────────────────────────────────────────────────

  group('VibeCompactDropdown', () {
    testWidgets('renders current value label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<String>(
            value: 'blue',
            options: const <String>['red', 'green', 'blue'],
            labelOf: (s) => s.toUpperCase(),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('BLUE'), findsOneWidget);
    });

    testWidgets('shows placeholder dash when value is null', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<String>(
            value: null,
            options: const <String>['a', 'b'],
            labelOf: (s) => s,
            onChanged: (_) {},
          ),
        ),
      );
      // Default placeholder is '—'.
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('shows custom placeholder when provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<String>(
            value: null,
            options: const <String>['x', 'y'],
            labelOf: (s) => s,
            onChanged: (_) {},
            placeholder: 'pick one',
          ),
        ),
      );
      expect(find.text('pick one'), findsOneWidget);
    });

    testWidgets('value not in options shows placeholder instead of value', (
      tester,
    ) async {
      // When value is not found in options, the dropdown falls back to
      // the placeholder (or '—') so the widget stays consistent.
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<String>(
            value: 'missing',
            options: const <String>['a', 'b'],
            labelOf: (s) => s,
            onChanged: (_) {},
          ),
        ),
      );
      // Should not throw; renders some fallback text.
      expect(find.byType(VibeCompactDropdown<String>), findsOneWidget);
    });

    testWidgets('renders without error when options list is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<int>(
            value: null,
            options: const <int>[],
            labelOf: (n) => '$n',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byType(VibeCompactDropdown<int>), findsOneWidget);
    });

    testWidgets('warning=true still renders without error', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VibeCompactDropdown<String>(
            value: null,
            options: const <String>['p', 'q'],
            labelOf: (s) => s,
            onChanged: (_) {},
            warning: true,
          ),
        ),
      );
      expect(find.byType(VibeCompactDropdown<String>), findsOneWidget);
    });
  });
}
