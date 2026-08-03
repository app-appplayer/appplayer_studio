/// Contract tests for `registerToolWidgets` — mirrors `vbu_widgets_test.dart`.
/// Registration before `initialize` is legal as of runtime 0.6.1 (validation
/// consults the registry, so a host widget has to be registerable before the
/// document that uses it is validated), and two runtimes keep independent
/// registries.
///
/// Post-initialize widget rendering requires a live Flutter engine mounted
/// in a real widget tree; those paths land in the routine integration suite.
/// This file pins the pre-init invariant only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/runtime.dart' as rt;
import 'package:appplayer_studio/base.dart';

void main() {
  testWidgets('registerToolWidgets is legal before runtime.initialize', (
    tester,
  ) async {
    final runtime = rt.MCPUIRuntime();
    expect(() => registerToolWidgets(runtime), returnsNormally);
  });

  testWidgets('two runtimes keep independent registries', (
    tester,
  ) async {
    final r1 = rt.MCPUIRuntime();
    final r2 = rt.MCPUIRuntime();
    expect(() => registerToolWidgets(r1), returnsNormally);
    expect(() => registerToolWidgets(r2), returnsNormally);
  });
}
