import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether the page containing this subtree is the one currently shown.
///
/// A page that is paused rather than destroyed stays mounted, and so does
/// everything inside it. Without this, an instance-level `lifecycle` block
/// (§6.8.2) heard `onInit`/`onMount`/`onReady` when its page opened and then
/// nothing ever again: leaving the page paused the *page*, and the widget that
/// had started a timer or a subscription in `onMount` kept running while
/// nobody was looking at it.
///
/// Carried as a notifier rather than a plain bool so a change does not rebuild
/// the subtree — the page's own widgets have no reason to rebuild because the
/// tab bar moved, and rebuilding them all on every switch is the cost that
/// keeping pages alive exists to avoid.
class PageActivityScope extends InheritedWidget {
  const PageActivityScope({
    super.key,
    required this.isActive,
    required super.child,
  });

  final ValueListenable<bool> isActive;

  static ValueListenable<bool>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PageActivityScope>()
      ?.isActive;

  @override
  bool updateShouldNotify(PageActivityScope oldWidget) =>
      oldWidget.isActive != isActive;
}
