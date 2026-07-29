/// VBU widgets are a DSL fork — they follow the DSL lifecycle contract.
///
/// The studio ships its own widget set (`VbuActivityBar`, `VbuBusyIndicator`,
/// …) registered onto the runtime. Being studio-owned does not put them
/// outside the spec: a document that declares §6.8.2 instance-level
/// `lifecycle` on a VBU widget must get the same hooks it would on a stock
/// one, or authors learn a rule that holds for half the catalog.
///
/// This is worth pinning rather than assuming. The runtime applies
/// `LifecycleHost.maybeWrap` inside `renderWidget`, which is generic — but VBU
/// widgets reach it through an extra wrapper (`_MetadataWrappingFactory`), and
/// "the generic path covers it" is exactly the kind of claim that is true until
/// someone adds a shortcut for registered widgets. Hooks were silently dropped
/// platform-wide until 0.5.3 for the same reason: nothing read them.
///
///   v1  a VBU widget's instance `lifecycle.onMount` fires
///   v2  `onUnmount` fires when it leaves the tree
///   v3  a VBU widget WITHOUT hooks is untouched (no wrapper, no cost)
///
/// Observed through STATE, not tools: `LifecycleManager` dispatches on its own
/// path and never reaches a registered tool executor, so a tool-based probe
/// reports "nothing ran" no matter what ran (cherry's instrumentation trap).
library;

import 'package:appplayer_studio/base.dart' show registerVbuWidgets;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _page(Map<String, dynamic> body) => <String, dynamic>{
      'type': 'page',
      'state': <String, dynamic>{
        'initial': <String, dynamic>{'mounted': 'no', 'gone': 'no'},
      },
      'content': body,
    };

Future<studio.MCPUIRuntime> _mount(
  WidgetTester tester,
  Map<String, dynamic> def,
) async {
  final runtime = studio.MCPUIRuntime();
  // `runAsync` — initialize awaits real async work the fake-async test clock
  // never advances, which hangs instead of failing (the shape a hooks bug
  // hides in).
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
  testWidgets('v1 a VBU widget instance lifecycle onMount fires',
      (tester) async {
    final runtime = await _mount(
      tester,
      _page(<String, dynamic>{
        'type': 'VbuBusyIndicator',
        'lifecycle': <String, dynamic>{
          'onMount': <String, dynamic>{
            'type': 'state',
            'action': 'set',
            'path': 'mounted',
            'value': 'yes',
          },
        },
      }),
    );
    expect(
      runtime.stateManager.get('mounted'),
      'yes',
      reason: 'a studio widget that declares §6.8.2 hooks must get them — '
          'otherwise the spec holds for half the catalog',
    );
    runtime.destroy();
  });

  testWidgets('v2 a VBU widget instance lifecycle onUnmount fires',
      (tester) async {
    final runtime = await _mount(
      tester,
      _page(<String, dynamic>{
        'type': 'VbuBusyIndicator',
        'lifecycle': <String, dynamic>{
          'onUnmount': <String, dynamic>{
            'type': 'state',
            'action': 'set',
            'path': 'gone',
            'value': 'yes',
          },
        },
      }),
    );

    // Replace the tree — the widget leaves, its teardown must run. A hook that
    // never fires leaks whatever it was meant to release (a subscription on a
    // single-peer board keeps the device streaming to nobody).
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(runtime.stateManager.get('gone'), 'yes');
    runtime.destroy();
  });

  testWidgets('v3 a VBU widget without hooks is left alone', (tester) async {
    final runtime = await _mount(
      tester,
      _page(<String, dynamic>{'type': 'VbuBusyIndicator'}),
    );
    // Untouched state = no hook ran, and by construction no wrapper was added.
    expect(runtime.stateManager.get('mounted'), 'no');
    expect(tester.takeException(), isNull);
    runtime.destroy();
  });
}
