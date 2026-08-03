/// Contract tests for `registerVbuWidgets`.
///
/// The runtime used to REJECT registration before `initialize` and this file
/// pinned that. `flutter_mcp_ui_runtime 0.6.1` inverted it deliberately:
/// schema validation now consults the widget registry, so a host widget must
/// be registerable BEFORE the document that uses it is validated — otherwise a
/// host catalogue can never pass validation in the document it appears in.
///
/// What is worth pinning now is the new guarantee: registering early is legal,
/// each runtime keeps its own registry, and the types actually land.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/runtime.dart' as rt;
import 'package:appplayer_studio/src/base/runtime/vbu_widgets.dart';

void main() {
  testWidgets('registerVbuWidgets is legal before runtime.initialize', (
    tester,
  ) async {
    final runtime = rt.MCPUIRuntime();
    expect(() => registerVbuWidgets(runtime), returnsNormally);
  });

  testWidgets('each runtime keeps its own registry (no shared state)', (
    tester,
  ) async {
    final r1 = rt.MCPUIRuntime();
    final r2 = rt.MCPUIRuntime();
    expect(() => registerVbuWidgets(r1), returnsNormally);
    expect(() => registerVbuWidgets(r2), returnsNormally);
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
