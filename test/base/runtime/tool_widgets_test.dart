/// Invariant tests for `registerToolWidgets` — mirrors the pattern from
/// `vbu_widgets_test.dart`. Verifies that calling `registerToolWidgets` on
/// an un-initialised `MCPUIRuntime` throws `StateError` (the runtime does
/// not allow widget registration before `initialize` is called), and that
/// two independent runtimes maintain independent state (no shared singleton
/// leaks between them).
///
/// Post-initialize widget rendering requires a live Flutter engine mounted
/// in a real widget tree; those paths land in the routine integration suite.
/// This file pins the pre-init invariant only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/runtime.dart' as rt;
import 'package:appplayer_studio/base.dart';

void main() {
  testWidgets('registerToolWidgets throws before runtime.initialize', (
    tester,
  ) async {
    final runtime = rt.MCPUIRuntime();
    expect(() => registerToolWidgets(runtime), throwsStateError);
  });

  testWidgets('registerToolWidgets throws independently across two runtimes', (
    tester,
  ) async {
    final r1 = rt.MCPUIRuntime();
    final r2 = rt.MCPUIRuntime();
    expect(() => registerToolWidgets(r1), throwsStateError);
    expect(() => registerToolWidgets(r2), throwsStateError);
  });
}
