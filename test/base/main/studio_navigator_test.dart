/// A document that brings no app of its own still needs somewhere to put a
/// dialog.
///
/// `application`-typed documents build a `MaterialApp` and attach its key while
/// mounted. A **page**-typed one builds nothing, so `NavigationService` pointed
/// at a key with no state and every `dialog` action silently did nothing —
/// measured live: `studio.ui.dismiss_dialog` answered `"nothing to pop"`, so no
/// dialog had ever opened.
///
/// The two properties that matter are opposite in direction: the floor has to
/// be there for a document without an app, and it must NOT displace one that
/// brought its own.
@TestOn('vm')
library;

import 'package:appplayer_studio/runtime.dart' as studio_rt;
import 'package:appplayer_studio/src/base/main/studio_navigator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attaching points the service at the studio shell', () {
    attachStudioNavigatorFloor();
    expect(
      identical(studio_rt.NavigationService().navigatorKey,
          studioRootNavigatorKey),
      isTrue,
    );
  });

  test('a document that brings its own navigator still wins', () {
    // The runtime attaches during `buildUI`, which runs after the mount-time
    // floor. If the floor were installed once at boot instead, or re-applied
    // afterwards, an application-typed document would lose its own Navigator
    // and its routes would act on the shell.
    attachStudioNavigatorFloor();
    final documentKey = GlobalKey<NavigatorState>(debugLabel: 'doc');
    studio_rt.NavigationService().attach(documentKey);

    expect(identical(studio_rt.NavigationService().navigatorKey, documentKey),
        isTrue);
  });

  test('re-attaching recovers the floor after such a document unmounts', () {
    // `attach` is last-wins and has no detach: once an application-typed
    // document has gone, the service still points at its dead Navigator. The
    // next mount re-applies the floor, which is why this is called per mount
    // rather than once.
    studio_rt.NavigationService()
        .attach(GlobalKey<NavigatorState>(debugLabel: 'gone'));
    attachStudioNavigatorFloor();

    expect(
      identical(studio_rt.NavigationService().navigatorKey,
          studioRootNavigatorKey),
      isTrue,
    );
  });

  test('calling it twice is a no-op', () {
    attachStudioNavigatorFloor();
    final first = studio_rt.NavigationService().navigatorKey;
    attachStudioNavigatorFloor();
    expect(identical(studio_rt.NavigationService().navigatorKey, first), isTrue);
  });
}
