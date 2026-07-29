/// The studio may ADD widgets. It may not quietly REPLACE spec ones.
///
/// `registerVbuWidgets` runs after the runtime has registered its own
/// catalogue, so any name it reuses silently takes that widget over. When the
/// replacement is a reimplementation it reads only the properties whoever wrote
/// it thought of, and everything else is dropped without an error: the widget
/// renders, reports success, and does nothing. That is how a spec-compliant
/// `onTap` came to produce a dead control on a real board, and how `maxLines`
/// / `overflow` / `disabled` / `loading` were being ignored across every bundle
/// the studio ran.
///
/// This is the boundary test for that. It does not care how the studio paints
/// anything — it cares that the set of spec widgets the studio takes over stays
/// a deliberate, reviewed list.
///
///   r1  the studio takes over EXACTLY the allowlisted spec widgets
///   r2  the studio's own widgets do not collide with the spec catalogue
///   r3  each takeover is a style-only DELEGATION — it holds the stock factory
///       it replaced, so the spec contract still runs
library;

import 'package:appplayer_studio/base.dart' show registerVbuWidgets;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter_test/flutter_test.dart';

/// Spec widgets the studio deliberately restyles.
///
/// Adding a name here is a decision, not a detail: it means the studio now sits
/// between every document and that widget. It is allowed ONLY as a style-only
/// delegation (r3) — never as a reimplementation.
const _allowedTakeovers = <String>{'button', 'text'};

Future<studio.MCPUIRuntime> _initialised(WidgetTester tester) async {
  final runtime = studio.MCPUIRuntime();
  await tester.runAsync(() => runtime.initialize(<String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{'type': 'text', 'value': ''},
      }, validateSchema: false));
  return runtime;
}

void main() {
  testWidgets('r1/r2 the studio takes over exactly the allowlisted widgets',
      (tester) async {
    final runtime = await _initialised(tester);
    final registry = runtime.engine.widgetRegistry;

    // Snapshot BY IDENTITY. A takeover is a name whose factory instance
    // changed — derived, not hand-listed, so a widget nobody remembered to put
    // in a list cannot slip through.
    final before = <String, Object?>{
      for (final t in registry.registeredTypes) t: registry.get(t),
    };
    expect(before.length, greaterThan(100),
        reason: 'sanity — the stock catalogue must be populated before the '
            'studio registers, or this test proves nothing');

    registerVbuWidgets(runtime);

    final takenOver = <String>{
      for (final t in registry.registeredTypes)
        if (before.containsKey(t) && !identical(before[t], registry.get(t))) t,
    };
    final added = <String>{
      for (final t in registry.registeredTypes)
        if (!before.containsKey(t)) t,
    };

    expect(takenOver, _allowedTakeovers,
        reason: 'the studio is the runtime plus its own catalogue. Taking over '
            'another spec widget narrows what every document can use — if that '
            'is intended, add it to _allowedTakeovers and make it a style-only '
            'delegation');
    expect(added, isNotEmpty,
        reason: 'sanity — the Vbu* catalogue should be registering');
    runtime.destroy();
  });

  testWidgets('r3 each takeover delegates to the stock factory it replaced',
      (tester) async {
    final runtime = await _initialised(tester);
    final registry = runtime.engine.widgetRegistry;

    final before = <String, Object?>{
      for (final t in _allowedTakeovers) t: registry.get(t),
    };
    for (final e in before.entries) {
      expect(e.value, isNotNull,
          reason: '${e.key} must exist in the stock catalogue');
    }

    registerVbuWidgets(runtime);

    for (final t in _allowedTakeovers) {
      final replacement = registry.get(t);
      expect(replacement, isNotNull);
      expect(identical(replacement, before[t]), isFalse,
          reason: '$t should have been restyled');
      // The replacement must still RUN the stock factory — a reimplementation
      // would not hold it. `stock` is the delegation seam.
      final held = (replacement as dynamic).stock;
      expect(identical(held, before[t]), isTrue,
          reason: 'the studio must contribute STYLE to $t, not reimplement it '
              '— a reimplementation reads only the properties its author '
              'recalled and drops the rest in silence');
    }
    runtime.destroy();
  });
}
