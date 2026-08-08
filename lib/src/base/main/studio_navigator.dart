/// The studio's own Navigator, offered to documents that do not bring one.
///
/// A document's `dialog` action reaches `NavigationService().navigatorKey` and
/// shows over that Navigator. A document typed `application` builds its own
/// `MaterialApp` and attaches its key while mounted — that path already works.
/// A **page**-typed document builds no app and attaches nothing, so the service
/// pointed at a key with no state and the dialog went nowhere: no dialog, no
/// error, no log. Measured — `studio.ui.dismiss_dialog` answered
/// `"nothing to pop"`, so nothing had ever opened.
///
/// The studio is the app those documents live in, so its shell Navigator is
/// the honest answer to "where should this dialog appear".
///
/// ATTACHED PER MOUNT, NOT ONCE AT BOOT. `attach` is last-wins: an
/// application-typed document attaches its own key while it is up, and after it
/// unmounts the service still points at that dead Navigator. Re-attaching as
/// each document mounts keeps the floor underneath without ever overriding a
/// document that brought its own — the runtime attaches during `buildUI`, which
/// runs after this.
library;

import 'package:flutter/widgets.dart';

import 'package:appplayer_studio/runtime.dart' as studio_rt;

/// The shell's Navigator. Installed on the studio `MaterialApp`.
final GlobalKey<NavigatorState> studioRootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'studio-root');

/// Point the runtime's navigation service at the studio shell.
///
/// Safe to call repeatedly: `attach` returns early when the key is unchanged.
void attachStudioNavigatorFloor() {
  studio_rt.NavigationService().attach(studioRootNavigatorKey);
}
