/// The bundle / authoring surface must CLAIM the Composition Profile.
///
/// `composition_seam_test.dart` proves the seam registers all four hooks when
/// asked. It cannot prove that the surface which renders a multi-origin bundle
/// actually asks — and that call site is exactly what was missing when this was
/// first wired: only the served-service surface had it, so the reference bundle
/// (`apps/multi_device.mbd`, a STUDIO bundle whose `view`s name connections)
/// would have rendered nothing but its fallbacks.
///
/// This is a PLACEMENT guard, deliberately source-level. Mounting
/// `DslWorkspaceView` for real needs a booted kernel, a bundle on disk and a
/// live client host — disproportionate for asserting that one registration line
/// exists, and slow enough that it would be the first test skipped. Its limit
/// is honest: it proves the call is written and reachable at the right point,
/// not that it behaves. Behaviour is c1–c14's job.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = 'lib/src/workspace/dsl_workspace_view.dart';

  test('the bundle surface registers composition hooks after initialize', () {
    final src = File(path).readAsStringSync();

    expect(
      src.contains('applyCompositionHooksToStudioRuntime'),
      isTrue,
      reason: 'without this the studio renders a multi-origin bundle with no '
          'resolver: every `view` falls back and the screen the profile exists '
          'for shows nothing. Wire it beside the other post-initialize '
          'registrations in the render path.',
    );

    // Order matters: the runtime asserts it is initialized before accepting a
    // resolver, and the first render must already resolve foreign refs — a
    // registration after `buildUI` is a screen that composes only on rebuild.
    final initAt = src.indexOf('await runtime.initialize(');
    final hooksAt = src.indexOf('applyCompositionHooksToStudioRuntime');
    expect(initAt, greaterThan(-1), reason: 'render path moved — update this guard');
    expect(
      hooksAt,
      greaterThan(initAt),
      reason: 'registration must follow initialize (the runtime rejects it '
          'otherwise) and precede the first build',
    );
  });
}
