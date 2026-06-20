import 'package:flutter/material.dart';

import 'package:appplayer_studio/base.dart';

/// Path segment within a widget tree. `String` = map key, `int` = list
/// index. Mixed lists are walked left-to-right by [atPath] / [pointerOf].
typedef WidgetPath = List<Object>;

/// Resolve a [WidgetPath] against [root]. Returns null when any segment
/// misses (so callers can fall back gracefully on stale selections).
dynamic atPath(dynamic root, WidgetPath path) {
  dynamic node = root;
  for (final s in path) {
    if (node == null) return null;
    if (s is int) {
      if (node is! List || s < 0 || s >= node.length) return null;
      node = node[s];
    } else if (s is String) {
      if (node is! Map) return null;
      node = node[s];
    } else {
      return null;
    }
  }
  return node;
}

/// Encode a [WidgetPath] as an RFC 6902 JSON Pointer fragment (each
/// segment escaped per spec). A leading `/` is included so callers can
/// concatenate to a parent pointer directly.
String pointerOf(WidgetPath path) {
  if (path.isEmpty) return '';
  final out = StringBuffer();
  for (final seg in path) {
    out.write('/');
    if (seg is int) {
      out.write(seg);
    } else {
      out.write(_escapePointerSegment(seg.toString()));
    }
  }
  return out.toString();
}

String _escapePointerSegment(String raw) =>
    raw.replaceAll('~', '~0').replaceAll('/', '~1');

/// Walk [root] looking for [target] by reference identity AND a
/// shallow-same-map fallback when the root itself was copied via
/// `Map.from`. Returns the JSON path or null.
///
/// The shallow-same fallback is needed because mcp_ui's runtime
/// `UIDefinition.fromJson` shallow-copies the page `content` map, so
/// the root RenderMetaData carries a fresh top-level identity even
/// though every value inside is the canonical reference.
WidgetPath? findCanonicalPath(Map<String, dynamic> root, Object target) {
  if (identical(root, target)) return const <Object>[];
  if (target is Map<String, dynamic> && shallowSameMap(root, target)) {
    return const <Object>[];
  }
  for (final entry in root.entries) {
    final v = entry.value;
    if (v is Map) {
      if (identical(v, target)) return <Object>[entry.key];
      final inner = findCanonicalPath(v.cast<String, dynamic>(), target);
      if (inner != null) return <Object>[entry.key, ...inner];
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final el = v[i];
        if (identical(el, target)) return <Object>[entry.key, i];
        if (el is Map) {
          final inner = findCanonicalPath(el.cast<String, dynamic>(), target);
          if (inner != null) return <Object>[entry.key, i, ...inner];
        }
      }
    }
  }
  return null;
}

/// Same as [findCanonicalPath] but without the root-level shallow-same
/// fallback. Used to prefer deeper exact matches over the root match
/// that the synthetic-page wrapping would otherwise win when a click
/// lands inside a child widget.
WidgetPath? findCanonicalPathIdentityOnly(
  Map<String, dynamic> root,
  Object target,
) {
  if (identical(root, target)) return const <Object>[];
  for (final entry in root.entries) {
    final v = entry.value;
    if (v is Map) {
      if (identical(v, target)) return <Object>[entry.key];
      final inner = findCanonicalPathIdentityOnly(
        v.cast<String, dynamic>(),
        target,
      );
      if (inner != null) return <Object>[entry.key, ...inner];
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final el = v[i];
        if (identical(el, target)) return <Object>[entry.key, i];
        if (el is Map) {
          final inner = findCanonicalPathIdentityOnly(
            el.cast<String, dynamic>(),
            target,
          );
          if (inner != null) return <Object>[entry.key, i, ...inner];
        }
      }
    }
  }
  return null;
}

/// Two-map shallow equality: same keys AND each value is reference-
/// identical. Detects `Map.from(x)` outputs whose values were not
/// further deep-copied.
bool shallowSameMap(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k)) return false;
    if (!identical(a[k], b[k])) return false;
  }
  return true;
}

/// Pick the most specific path among the candidate metadata refs
/// found at a tap location. The hit path arrives leaf-first; we
/// prefer an identity match (deeper wins) and fall back to the
/// shallow-same root match only when no identity hit exists at all.
/// Returns null when none of the candidates lies in [root].
WidgetPath? selectCanonicalPath(
  Map<String, dynamic> root,
  Iterable<Object> hitPathLeafFirst,
) {
  WidgetPath? shallowFallback;
  for (final candidate in hitPathLeafFirst) {
    if (candidate is! Map<String, dynamic>) continue;
    final identityPath = findCanonicalPathIdentityOnly(root, candidate);
    if (identityPath != null) return identityPath;
    shallowFallback ??= findCanonicalPath(root, candidate);
  }
  return shallowFallback;
}

/// Resolve the canonical path of the deepest tapped widget by walking
/// the [hitPathLeafFirst] chain of metadata maps and stitching together
/// each parent → child step from their own structural relationships —
/// independently of [root]'s reference identity.
///
/// Why this exists: identity-only resolvers need each candidate to be
/// reference-identical to a node reachable from [root]. Right after a
/// canonical patch the runtime's metadata refs land before the shell's
/// projection rebuild has propagated a fresh [root] through widget
/// params, producing a transient identity mismatch — and the user
/// sees the row collapse onto the cursor while the buttons silently
/// fail to register. The chain resolver is immune: it derives the
/// path purely from the runtime's own metadata nesting (which is
/// always self-consistent) and lets the consuming shell re-resolve
/// the path against whatever canonical state IT currently holds.
///
/// Returns null when the chain has fewer than two entries (no
/// parent-child relationship to derive a non-root path from).
WidgetPath? resolveTapPathFromChain(
  Map<String, dynamic> root,
  Iterable<Object> hitPathLeafFirst,
) {
  // Filter to MetaData maps. Order is preserved (leaf-first).
  final chain = <Map<String, dynamic>>[];
  for (final c in hitPathLeafFirst) {
    if (c is Map<String, dynamic>) chain.add(c);
  }
  if (chain.isEmpty) return null;
  // Single-element chain: the cursor sits in the empty area of the
  // outermost rendered MetaData. Treat as root selection IFF that
  // outermost map is plausibly [root] (identity / shallow). Otherwise
  // we'd select something that isn't in our subtree at all.
  if (chain.length == 1) {
    final only = chain.first;
    if (identical(only, root) || shallowSameMap(only, root)) {
      return const <Object>[];
    }
    return null;
  }
  final out = <Object>[];
  // Walk root → leaf, deriving each step from the parent metadata's
  // own structure. chain[i] is the parent of chain[i-1] in the cursor
  // hit path (because hit-test is leaf-first).
  //
  // STOP at the first parent that does not directly reference its
  // child — that's the boundary between the canonical address space
  // and an instantiated subtree (e.g. a `use` widget hosting a deep-
  // cloned template body). Continuing past this boundary would paste
  // the inner subtree's path onto the outer parent and produce a path
  // that resolves to nothing on `atPath(canonical, …)`. The caller
  // gets the deepest canonical-addressable node — i.e. the `use`
  // widget itself — which is what the user can edit anyway.
  for (var i = chain.length - 1; i > 0; i--) {
    final parent = chain[i];
    final child = chain[i - 1];
    final segment = _findChildSegment(parent, child);
    if (segment == null) break;
    out.addAll(segment);
  }
  if (out.isEmpty) return null;
  return out;
}

/// Locate `child` as a direct value inside `parent` and return the
/// path segment (`[key]` for map slot, `[key, index]` for list slot).
/// Returns null when not found at this level.
///
/// Three-tier match (each strictly more permissive than the previous):
///
/// 1. **Identity** — `identical(parent_value, child)`. The fast path;
///    works whenever the runtime hands us the same Map ref it stores
///    in the canonical.
/// 2. **Shallow-same** — same keys + each value `identical`. Catches
///    the runtime's `Map.from(content)` shallow copy where scalar
///    fields are canonicalized strings/numbers and nested Maps are
///    still the canonical refs.
/// 3. **Structural** — same `type` + matching scalar fields (string /
///    num / bool). Workaround for a separate runtime / Flutter
///    reconciliation bug where a child's RenderMetaData stays stuck
///    on a stale Map reference whose nested Maps differ from the
///    parent's `children` list (so shallow-same fails). The diagnostic
///    dump captured this live.
List<Object>? _findChildSegment(
  Map<String, dynamic> parent,
  Map<String, dynamic> child,
) {
  // Tier 1+2: identity then shallow-same.
  for (final entry in parent.entries) {
    final v = entry.value;
    if (v is Map) {
      if (identical(v, child)) return <Object>[entry.key];
      if (v is Map<String, dynamic> && shallowSameMap(v, child)) {
        return <Object>[entry.key];
      }
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final el = v[i];
        if (identical(el, child)) return <Object>[entry.key, i];
        if (el is Map<String, dynamic> && shallowSameMap(el, child)) {
          return <Object>[entry.key, i];
        }
      }
    }
  }
  // Tier 3: structural fallback. Separate pass so identity / shallow
  // hits always win when present (deeper or more current).
  for (final entry in parent.entries) {
    final v = entry.value;
    if (v is Map<String, dynamic>) {
      if (_structurallySame(v, child)) return <Object>[entry.key];
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final el = v[i];
        if (el is Map<String, dynamic> && _structurallySame(el, child)) {
          return <Object>[entry.key, i];
        }
      }
    }
  }
  return null;
}

/// Two maps share the same `type` and every scalar field (string,
/// num, bool) at the top level matches. Nested Maps / Lists are
/// ignored — they may legitimately have different identities (rebuilt
/// `onTap` action maps, etc.) without changing the widget identity.
/// Used as a last-resort match when identity / shallow have failed.
bool _structurallySame(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a['type'] != b['type']) return false;
  for (final k in a.keys) {
    final av = a[k];
    if (av is String || av is num || av is bool) {
      if (b[k] != av) return false;
    }
  }
  for (final k in b.keys) {
    final bv = b[k];
    if (bv is String || bv is num || bv is bool) {
      if (a[k] != bv) return false;
    }
  }
  return true;
}

/// Public alias for [_structurallySame] — exported so the highlight-
/// rect walker (in `preview_mcp_ui.dart`) can apply the same
/// reference-drift workaround when matching a target node against a
/// `RenderMetaData.metaData` payload that may be a stale Map ref from
/// an earlier render generation.
bool structurallySameWidget(Map<String, dynamic> a, Map<String, dynamic> b) =>
    _structurallySame(a, b);

/// One row of the [WidgetTreeView] traversal. Built ahead of render so
/// the widget tree can be rendered as a flat list with virtual indents.
class _TreeRow {
  _TreeRow({
    required this.depth,
    required this.path,
    required this.node,
    required this.hasChildren,
  });

  final int depth;
  final WidgetPath path;
  final Map<String, dynamic> node;
  final bool hasChildren;
}

/// Read-only collapsible tree view of a widget subtree (a page's
/// `content` or a component template). Vibe never drags / rearranges
/// nodes — selection is the only interaction.
class WidgetTreeView extends StatefulWidget {
  const WidgetTreeView({
    super.key,
    required this.root,
    required this.selectedPath,
    required this.onSelect,
  });

  /// Root widget node (the map with `type`). Tree starts at this map and
  /// recurses through child / children edges.
  final Map<String, dynamic> root;

  /// Currently selected path within [root]. `[]` selects the root.
  /// `null` means nothing selected.
  final WidgetPath? selectedPath;

  /// Fires whenever the user picks a node.
  final ValueChanged<WidgetPath> onSelect;

  @override
  State<WidgetTreeView> createState() => _WidgetTreeViewState();
}

class _WidgetTreeViewState extends State<WidgetTreeView> {
  // Collapsed state by path-as-string. Defaults to expanded; toggling
  // adds the path to the set.
  final Set<String> _collapsed = <String>{};

  bool _isCollapsed(WidgetPath p) => _collapsed.contains(_pathKey(p));

  String _pathKey(WidgetPath p) => p.map((s) => '$s').join('/');

  void _toggle(WidgetPath p) {
    final key = _pathKey(p);
    setState(() {
      if (_collapsed.contains(key)) {
        _collapsed.remove(key);
      } else {
        _collapsed.add(key);
      }
    });
  }

  /// Walk the widget tree and emit one row per visible node. Honors
  /// the [_collapsed] set — collapsed parents skip their subtree.
  List<_TreeRow> _buildRows() {
    final rows = <_TreeRow>[];
    void visit(Map<String, dynamic> node, int depth, WidgetPath path) {
      final children = _childEdges(node);
      rows.add(
        _TreeRow(
          depth: depth,
          path: List.unmodifiable(path),
          node: node,
          hasChildren: children.isNotEmpty,
        ),
      );
      if (_isCollapsed(path)) return;
      for (final edge in children) {
        if (edge.isList) {
          for (var i = 0; i < edge.list.length; i++) {
            final child = edge.list[i];
            if (child is Map<String, dynamic>) {
              visit(child, depth + 1, [...path, edge.key, i]);
            }
          }
        } else {
          final child = edge.value;
          if (child is Map<String, dynamic>) {
            visit(child, depth + 1, [...path, edge.key]);
          }
        }
      }
    }

    visit(widget.root, 0, const <Object>[]);
    return rows;
  }

  /// Identify keys whose values look like child widgets — either a
  /// single map with `type`, or a list of such maps. Common edges:
  /// `child`, `children`, `body`, `header`, `footer`, `slots`. The
  /// algorithm is value-driven so unknown widgets still tree out.
  List<_ChildEdge> _childEdges(Map<String, dynamic> node) {
    final edges = <_ChildEdge>[];
    for (final entry in node.entries) {
      final v = entry.value;
      if (v is Map && v.containsKey('type')) {
        edges.add(_ChildEdge.single(entry.key, v));
      } else if (v is List && v.isNotEmpty && v.every(_isWidgetMap)) {
        edges.add(_ChildEdge.list(entry.key, v));
      }
    }
    return edges;
  }

  static bool _isWidgetMap(Object? v) => v is Map && v.containsKey('type');

  @override
  Widget build(BuildContext context) {
    final rows = _buildRows();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: VibeTokens.space1),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        final selected =
            widget.selectedPath != null &&
            _pathKey(widget.selectedPath!) == _pathKey(row.path);
        return _TreeRowTile(
          row: row,
          selected: selected,
          collapsed: _isCollapsed(row.path),
          onTap: () => widget.onSelect(row.path),
          onToggle: row.hasChildren ? () => _toggle(row.path) : null,
        );
      },
    );
  }
}

class _ChildEdge {
  _ChildEdge.single(this.key, Map child)
    : value = child,
      list = const <dynamic>[],
      isList = false;
  _ChildEdge.list(this.key, this.list) : value = null, isList = true;
  final String key;
  final dynamic value;
  final List<dynamic> list;
  final bool isList;
}

class _TreeRowTile extends StatefulWidget {
  const _TreeRowTile({
    required this.row,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    required this.onToggle,
  });

  final _TreeRow row;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onToggle;

  @override
  State<_TreeRowTile> createState() => _TreeRowTileState();
}

class _TreeRowTileState extends State<_TreeRowTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final type = widget.row.node['type']?.toString() ?? '?';
    final preview = _previewLabel(widget.row.node);
    final indent = widget.row.depth * 14.0;
    final bg =
        widget.selected
            ? c.surface3
            : (_hovered ? c.surface2 : Colors.transparent);
    final accent = widget.selected ? c.mint : c.borderDefault;
    final caret =
        widget.row.hasChildren
            ? Icon(
              widget.collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 14,
              color: c.textSecondary,
            )
            : const SizedBox(width: 14);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          color: bg,
          padding: EdgeInsets.fromLTRB(
            VibeTokens.space2 + indent,
            2,
            VibeTokens.space2,
            2,
          ),
          child: Row(
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onToggle,
                child: SizedBox(width: 14, child: caret),
              ),
              const SizedBox(width: 4),
              Container(width: 3, height: 14, color: accent),
              const SizedBox(width: 6),
              Text(
                type,
                style: vibeMono(
                  size: 12,
                  weight: FontWeight.w500,
                  color: c.textPrimary,
                ),
              ),
              if (preview != null) ...<Widget>[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    preview,
                    style: vibeMono(size: 11, color: c.textTertiary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Right-of-type hint — shows obvious leaf values so the tree is
  /// scannable. Truncates long strings; counts collections.
  String? _previewLabel(Map<String, dynamic> node) {
    final text = node['text'];
    if (text is String && text.isNotEmpty) {
      final t = text.length > 24 ? '${text.substring(0, 24)}…' : text;
      return '"$t"';
    }
    final label = node['label'];
    if (label is String && label.isNotEmpty) {
      final t = label.length > 24 ? '${label.substring(0, 24)}…' : label;
      return '"$t"';
    }
    final children = node['children'];
    if (children is List) return '[${children.length}]';
    return null;
  }
}
