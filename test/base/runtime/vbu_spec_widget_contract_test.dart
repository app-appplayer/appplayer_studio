/// The studio must not narrow a widget the DSL spec defines.
///
/// The studio is the runtime plus its own `Vbu*` catalogue. `button` and `text`
/// are SPEC widgets; the studio only contributes styling to them. They used to
/// be reimplemented, and a reimplementation reads only the properties whoever
/// wrote it happened to think of:
///
///   * `button` accepted 4 of the stock factory's ~25. A spec-compliant `onTap`
///     produced a control that looked enabled and did nothing — measured on a
///     real ESP32 whose page uses `onTap` 7× and `click` 0×.
///   * `text` accepted 5 of 15. `maxLines` / `overflow` / `textAlign` and the
///     rest were dropped.
///
/// Every gap was invisible: the widget rendered, reported success, did nothing.
/// These lock the properties that were being dropped, so a future style change
/// cannot quietly re-narrow the contract. They are deliberately about
/// BEHAVIOUR the spec promises, not about how the studio paints it.
///
///   s1  button `disabled` is honoured (was ignored → an inert-by-spec control
///       was fully live)
///   s2  button `enabled:false` likewise
///   s3  button `loading` is honoured
///   s4  button `onTap` fires and `click` still fires (the found regression)
///   s5  text `maxLines` + `overflow` are honoured
///   s6  text `textAlign` is honoured
///   s7  the studio still styles both (delegation did not drop the look)
library;

import 'package:appplayer_studio/base.dart' show registerVbuWidgets;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _page(Map<String, dynamic> child) => <String, dynamic>{
      'type': 'page',
      'state': <String, dynamic>{
        'initial': <String, dynamic>{'fired': 'no'},
      },
      'content': child,
    };

const _fire = <String, dynamic>{
  'type': 'state',
  'action': 'set',
  'path': 'fired',
  'value': 'yes',
};

Future<studio.MCPUIRuntime> _mount(
  WidgetTester tester,
  Map<String, dynamic> def,
) async {
  final runtime = studio.MCPUIRuntime();
  await tester.runAsync(() => runtime.initialize(def, validateSchema: false));
  registerVbuWidgets(runtime);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => runtime.buildUI(context: context)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  return runtime;
}

void main() {
  group('button — spec properties the studio used to drop', () {
    testWidgets('s1 `disabled` is honoured', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'button',
          'label': 'Go',
          'disabled': true,
          'onTap': _fire,
        }),
      );

      await tester.tap(find.text('Go'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));

      expect(runtime.stateManager.get('fired'), 'no',
          reason: 'a button the document disabled must not act');
      runtime.destroy();
    });

    testWidgets('s2 `enabled: false` is honoured', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'button',
          'label': 'Go',
          'enabled': false,
          'onTap': _fire,
        }),
      );

      await tester.tap(find.text('Go'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));

      expect(runtime.stateManager.get('fired'), 'no');
      runtime.destroy();
    });

    testWidgets('s3 `loading` is honoured', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'button',
          'label': 'Go',
          'loading': true,
          'onTap': _fire,
        }),
      );

      // `loading` swaps the label for a spinner, so there is no 'Go' text to
      // hit — tap the button itself.
      final btn = find.byWidgetPredicate((w) => w is ButtonStyleButton);
      expect(btn, findsOneWidget);
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));

      expect(runtime.stateManager.get('fired'), 'no',
          reason: 'a loading button must not fire again mid-flight');
      runtime.destroy();
    });

    testWidgets('s4 the spec property `onTap` fires', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'button',
          'label': 'Go',
          'onTap': _fire,
        }),
      );
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(runtime.stateManager.get('fired'), 'yes',
          reason: 'the spec property — this is what was dead on a real board');
      runtime.destroy();
    });

    testWidgets('s4b the legacy alias `click` still fires', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'button',
          'label': 'Go',
          'click': _fire,
        }),
      );
      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(runtime.stateManager.get('fired'), 'yes',
          reason: 'existing studio documents use the alias');
      runtime.destroy();
    });
  });

  group('text — spec properties the studio used to drop', () {
    testWidgets('s5 `maxLines` + `overflow` are honoured', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'text',
          'text': 'one two three four five six seven eight nine ten eleven',
          'maxLines': 1,
          'overflow': 'ellipsis',
        }),
      );

      final t = tester.widget<Text>(find.byType(Text).first);
      expect(t.maxLines, 1, reason: 'dropped by the reimplementation');
      expect(t.overflow, TextOverflow.ellipsis);
      runtime.destroy();
    });

    testWidgets('s6 `textAlign` is honoured', (tester) async {
      final runtime = await _mount(
        tester,
        _page(<String, dynamic>{
          'type': 'text',
          'text': 'centred',
          'textAlign': 'center',
        }),
      );

      final t = tester.widget<Text>(find.byType(Text).first);
      expect(t.textAlign, TextAlign.center);
      runtime.destroy();
    });
  });

  testWidgets('s7 the studio still styles both', (tester) async {
    final runtime = await _mount(
      tester,
      _page(<String, dynamic>{
        'type': 'text',
        'text': 'styled',
        'variant': 'titleLarge',
      }),
    );

    final t = tester.widget<Text>(find.text('styled'));
    // The studio's compact mono scale, not the M3 default (titleLarge = 22).
    expect(t.style?.fontSize, 16,
        reason: 'delegating to the stock factory must not lose the studio look');
    expect(t.style?.fontWeight, FontWeight.w600);
    runtime.destroy();
  });
}
