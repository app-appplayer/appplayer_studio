/// Invariant tests for `registerVbuWidgets` — verifies the
/// `MCPUIRuntime.registerWidget` contract that vbu_* atoms can't be
/// registered before the runtime is initialised. The actual rendered-
/// widget coverage lands when the studio mounts a real DSL workspace,
/// which the existing routine scenarios already exercise; this test
/// pins the pre-init invariant so accidental re-ordering at boot
/// fails loudly instead of silently.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/runtime.dart' as rt;
import 'package:appplayer_studio/src/base/runtime/vbu_widgets.dart';

void main() {
  testWidgets('registerVbuWidgets throws before runtime.initialize', (
    tester,
  ) async {
    final runtime = rt.MCPUIRuntime();
    expect(() => registerVbuWidgets(runtime), throwsStateError);
  });

  testWidgets('throws independently across runtimes (no shared state)', (
    tester,
  ) async {
    final r1 = rt.MCPUIRuntime();
    final r2 = rt.MCPUIRuntime();
    expect(() => registerVbuWidgets(r1), throwsStateError);
    expect(() => registerVbuWidgets(r2), throwsStateError);
  });

  // NOTE: post-initialize registration of vbu_* atoms would need a
  // `runtime.initialize` mounted against a real `Element` tree — that
  // path drives the engine's renderer + dispatcher startup and hangs
  // indefinitely inside `flutter test` (10-minute timeout observed
  // when the test fixture supplied a synthetic page loader). The real
  // post-init coverage lands when the studio mounts a workspace via
  // `DslWorkspaceView` (routine 6 scenarios in the integration suite
  // exercise this end to end). The two invariants above pin the
  // pre-init contract, which is what unit tests can safely assert.
}
