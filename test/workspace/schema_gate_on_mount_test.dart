/// The workspace mounts documents with schema validation ON, and that only
/// works because host widgets are registered BEFORE `initialize`.
///
/// The runtime masks any type its widget registry claims before checking a
/// document against the spec schema — but it reads the registry at validation
/// time, which is inside `initialize`. Register afterwards and the registry is
/// empty for the check: every `Vbu*` document is rejected as malformed. That
/// is why the gate was turned off here in the first place, and measuring the
/// bundle corpus showed the cost of leaving it off — 10 of 54 documents
/// rejected under the old order, 0 under the new one.
///
/// Two guards, because they fail for different reasons:
///   1. Behaviour — the runtime's masking really is order-sensitive.
///   2. Placement — this call site really does use that order, and does not
///      pass `validateSchema: false` to sidestep the question.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart' as base;
import 'package:appplayer_studio/runtime.dart' as studio;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _vbuDoc() => jsonDecode(
      '{"type":"page","content":{"type":"VbuHeroPanel"}}',
    ) as Map<String, dynamic>;

Future<Object?> _mount(
  WidgetTester tester,
  studio.MCPUIRuntime runtime,
  Map<String, dynamic> doc,
) {
  // The catch must sit inside `runAsync`: `initialize` throws from the async
  // zone it establishes, so a try/catch around the await never sees it and
  // every rejection reads as an acceptance.
  return tester.runAsync<Object?>(() async {
    try {
      await runtime.initialize(doc);
      return null;
    } catch (e) {
      return e;
    }
  });
}

bool _isSchemaRejection(Object? e) =>
    e is StateError && e.message.contains('schema validation failed');

void main() {
  testWidgets('registering host widgets first is what lets the gate stay on',
      (tester) async {
    final late = studio.MCPUIRuntime();
    final lateFailure = await _mount(tester, late, _vbuDoc());
    expect(
      _isSchemaRejection(lateFailure),
      isTrue,
      reason: 'a host widget the registry does not yet know is read as a '
          'malformed node — this is the behaviour the mount order works '
          'around, so if it ever stops holding the guard below is moot',
    );

    final early = studio.MCPUIRuntime();
    base.registerToolWidgets(early);
    base.registerVbuWidgets(early);
    final earlyFailure = await _mount(tester, early, _vbuDoc());
    expect(
      earlyFailure,
      isNull,
      reason: 'registered first, the same document must clear the gate',
    );
  });

  test('the workspace registers host widgets before it initializes', () {
    const path = 'lib/src/workspace/dsl_workspace_view.dart';
    final src = File(path).readAsStringSync();

    final initAt = src.indexOf('await runtime.initialize(');
    final vbuAt = src.indexOf('base.registerVbuWidgets(runtime)');
    final toolAt = src.indexOf('base.registerToolWidgets(runtime)');
    expect(initAt, greaterThan(-1),
        reason: 'render path moved — update this guard');
    expect(vbuAt, greaterThan(-1));
    expect(toolAt, greaterThan(-1));

    expect(
      vbuAt,
      lessThan(initAt),
      reason: 'registered after initialize, every Vbu document fails schema '
          'validation at mount',
    );
    expect(toolAt, lessThan(initAt));

    // The old workaround. If it comes back, the gate is off again and the
    // guard above passes while nothing is actually being validated.
    final initCall = src.substring(initAt, src.indexOf(');', initAt));
    expect(
      initCall.contains('validateSchema'),
      isFalse,
      reason: 'the mount must take the runtime default (on). Passing the flag '
          'here is how the gate was disabled before.',
    );
  });
}
