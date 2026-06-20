import 'package:flutter/widgets.dart';

/// Wrap [child] with an inspector-friendly [MetaData] node so the studio's
/// layout-snapshot walker (`studio.renderer.layout_snapshot`) can surface
/// this widget under a stable identifier, and the rect resolver
/// (`studio.ui.tap({elementId: ...})`) can target the same node by name
/// without anyone having to compute logical-pixel coordinates.
///
/// Use everywhere the chrome / built-in app shell renders a click target —
/// sub-tab cards, list rows, header trailing actions, dialog action buttons.
/// The wrapper itself is `HitTestBehavior.translucent`, so the underlying
/// `GestureDetector` / `InkWell` still receives the user's tap; we just
/// participate in the hit-test chain so the studio's automation surface
/// can resolve a path back to this node.
///
/// Conventions:
///   - `type` — short, machine-stable group key (e.g. `'sub_tab'`,
///     `'instance_card'`, `'pages_list_row'`, `'dialog_action'`).
///   - `id` — primary instance key inside the group (page id, layer id,
///     action slot). Snapshot id-only resolver hits this first.
///   - `label` / `text` / `title` — optional human-readable fallback keys
///     so id-less surfaces (icon buttons) can still be addressed by their
///     visible label.
///   - Extra fields pass through unchanged so callers can decorate without
///     a schema change.
Widget inspectTag({
  required String type,
  String? id,
  String? label,
  String? text,
  String? title,
  Map<String, dynamic>? extra,
  required Widget child,
}) {
  final meta = <String, dynamic>{'type': type};
  if (id != null && id.isNotEmpty) meta['id'] = id;
  if (label != null && label.isNotEmpty) meta['label'] = label;
  if (text != null && text.isNotEmpty) meta['text'] = text;
  if (title != null && title.isNotEmpty) meta['title'] = title;
  if (extra != null) {
    for (final entry in extra.entries) {
      if (!meta.containsKey(entry.key)) meta[entry.key] = entry.value;
    }
  }
  return MetaData(
    metaData: meta,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}
