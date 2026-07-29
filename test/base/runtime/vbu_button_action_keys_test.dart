/// The studio's `button` override must accept the SPEC property, not a subset.
///
/// `registerVbuWidgets` replaces the stock DSL `button` with a studio-styled
/// one. The stock factory takes `onTap` (spec) with `click` as a legacy alias;
/// the override took only `click`. Every document written to the spec therefore
/// rendered a button that looked enabled and did nothing — no error, no log,
/// no visual difference from a working one. Found on a real ESP32 whose page
/// uses `onTap` 7× and `click` 0×: the composed screen rendered, streamed live
/// values, and could not be operated.
///
/// VBU is a fork of the DSL, not a dialect of it. An override that narrows the
/// accepted property set breaks exactly the authors who followed the spec, and
/// breaks them silently.
///
///   b1  `onTap` fires (the spec property — the regression)
///   b2  `click` still fires (legacy alias not dropped)
///   b3  neither declared → renders, does not throw, does nothing
library;

import 'package:appplayer_studio/base.dart' show registerVbuWidgets;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _pageWithButton(Map<String, dynamic> buttonProps) => {
      'type': 'page',
      'state': <String, dynamic>{
        'initial': <String, dynamic>{'fired': 'no'},
      },
      'content': <String, dynamic>{
        'type': 'button',
        'label': 'Go',
        ...buttonProps,
      },
    };

const _setFired = <String, dynamic>{
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
  testWidgets('b1 the spec property `onTap` fires', (tester) async {
    final runtime = await _mount(
      tester,
      _pageWithButton(<String, dynamic>{'onTap': _setFired}),
    );

    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      runtime.stateManager.get('fired'),
      'yes',
      reason: 'a button written to the spec must act — reading only the legacy '
          'alias makes every spec-compliant document render a dead control',
    );
    runtime.destroy();
  });

  testWidgets('b2 the legacy alias `click` still fires', (tester) async {
    final runtime = await _mount(
      tester,
      _pageWithButton(<String, dynamic>{'click': _setFired}),
    );

    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(runtime.stateManager.get('fired'), 'yes',
        reason: 'existing studio documents use the alias — fixing the spec '
            'property must not drop it');
    runtime.destroy();
  });

  testWidgets('b3 a button with no action renders and is inert', (tester) async {
    final runtime = await _mount(tester, _pageWithButton(const {}));

    expect(find.text('Go'), findsOneWidget);
    await tester.tap(find.text('Go'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(runtime.stateManager.get('fired'), 'no');
    expect(tester.takeException(), isNull);
    runtime.destroy();
  });
}
