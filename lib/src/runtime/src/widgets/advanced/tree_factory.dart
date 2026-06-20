import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for Tree widgets (Advanced conformance level)
/// Renders a hierarchical tree view using ExpansionTile
class TreeWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract tree properties. Use nullable resolve so absent `data`
    // returns empty rather than throwing a non-nullable cast.
    final data =
        (context.resolve<List<dynamic>?>(properties['data'])) ?? [];
    // Spec §10.11 canonical `initiallyExpanded`; `expandAll` kept as legacy.
    final expandAll = context.resolve<bool>(
        properties['initiallyExpanded'] ?? properties['expandAll'] ?? false);
    // ignore: unused_local_variable
    final childrenKey = properties['childrenKey'] as String? ?? 'children';
    // ignore: unused_local_variable
    final onNodeTap = properties['onNodeTap'] as Map<String, dynamic>?;
    final showLines = context.resolve<bool>(properties['showLines'] ?? true);
    final selectable = context.resolve<bool>(properties['selectable'] ?? false);
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']);
    final indentation = (properties['indentation'] as num?)?.toDouble() ?? 24.0;
    // Spec §10.11 `itemPadding`: EdgeInsets applied inside every row so the
    // vertical component drives row height. Falls back to the design-doc
    // default of 4px vertical + 8px right.
    final itemPadding = parseEdgeInsets(properties['itemPadding']) ??
        const EdgeInsets.only(top: 4, bottom: 4, right: 8);
    final expandable =
        context.resolve<bool>(properties['expandable'] ?? true);
    final itemTemplate =
        properties['itemTemplate'] as Map<String, dynamic>?;

    // Extract colors — theme-adaptive fallbacks. Line color follows
    // divider; selected highlight is a soft primary tint that reads
    // in both light and dark modes.
    final lineColor =
        parseColor(context.resolve(properties['lineColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey;
    final selectedColor = parseColor(
            context.resolve(properties['selectedColor']), context) ??
        (context.themeManager.getColorValue('primary')?.withValues(alpha: 0.2)) ??
        Colors.blue.shade100;
    final onSurfaceColor =
        context.themeManager.getColorValue('onSurface') ?? Colors.black87;

    // Extract action handlers
    final onSelect = (properties['onSelect'] ?? properties['select']) as Map<String, dynamic>?;
    final onExpand = properties['onExpand'] as Map<String, dynamic>?;
    final onCollapse = properties['onCollapse'] as Map<String, dynamic>?;

    if (data.isEmpty) {
      return applyCommonWrappers(
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          child: Text(
            'No tree data',
            style: TextStyle(color: onSurfaceColor.withValues(alpha: 0.6)),
          ),
        ),
        properties,
        context,
      );
    }

    // Build tree nodes
    Widget tree = _TreeView(
      nodes: data,
      expandAll: expandAll,
      expandable: expandable,
      showLines: showLines,
      selectable: selectable,
      indentation: indentation,
      itemPadding: itemPadding,
      itemTemplate: itemTemplate,
      lineColor: lineColor,
      selectedColor: selectedColor,
      onSelect: onSelect,
      onExpand: onExpand,
      onCollapse: onCollapse,
      context: context,
      depth: 0,
    );

    // Wrap in scrollable container
    Widget result = SingleChildScrollView(
      child: tree,
    );

    if (width != null || height != null) {
      result = SizedBox(
        width: width,
        height: height,
        child: result,
      );
    }

    return applyCommonWrappers(result, properties, context);
  }
}

/// Stateful tree view widget
class _TreeView extends StatefulWidget {
  final List<dynamic> nodes;
  final bool expandAll;
  final bool expandable;
  final bool showLines;
  final bool selectable;
  final double indentation;
  final EdgeInsets itemPadding;
  final Map<String, dynamic>? itemTemplate;
  final Color lineColor;
  final Color selectedColor;
  final Map<String, dynamic>? onSelect;
  final Map<String, dynamic>? onExpand;
  final Map<String, dynamic>? onCollapse;
  final RenderContext context;
  final int depth;

  const _TreeView({
    required this.nodes,
    required this.expandAll,
    required this.expandable,
    required this.showLines,
    required this.selectable,
    required this.indentation,
    required this.itemPadding,
    this.itemTemplate,
    required this.lineColor,
    required this.selectedColor,
    this.onSelect,
    this.onExpand,
    this.onCollapse,
    required this.context,
    required this.depth,
  });

  @override
  State<_TreeView> createState() => _TreeViewState();
}

class _TreeViewState extends State<_TreeView> {
  String? _selectedNodeId;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widget.nodes.map((node) => _buildNode(node)).toList(),
    );
  }

  Widget _buildNode(dynamic nodeData) {
    if (nodeData is! Map) return const SizedBox.shrink();

    final node = nodeData as Map<String, dynamic>;
    final id = node['id']?.toString() ?? '';
    final label = widget.context.resolve<String>(node['label'] ?? '');
    final iconName = node['icon'] as String?;
    final children = node['children'] as List<dynamic>?;
    final hasChildren = children != null && children.isNotEmpty;
    final isSelected = _selectedNodeId == id;

    // Parse icon
    final icon = iconName != null ? _parseIcon(iconName) : null;

    // Build label widget - use itemTemplate if provided
    Widget labelWidget;
    if (widget.itemTemplate != null) {
      final childContext = widget.context.createChildContext(
        variables: {
          'item': node,
          'depth': widget.depth,
          'hasChildren': hasChildren,
          'isSelected': isSelected,
        },
      );
      labelWidget = widget.context.renderer
          .renderWidget(widget.itemTemplate!, childContext);
    } else {
      labelWidget = Container(
        decoration: isSelected
            ? BoxDecoration(
                color: widget.selectedColor,
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: hasChildren ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      );
    }

    if (hasChildren && widget.expandable) {
      // File-explorer-style expandable row: chevron + optional icon + label,
      // with children rendered directly below (not as a Material
      // ExpansionTile, which introduced trailing-arrow layout artifacts).
      return _ExpandableNode(
        key: ValueKey(id),
        initiallyExpanded: widget.expandAll,
        indentationLeft: widget.indentation * widget.depth,
        itemPadding: widget.itemPadding,
        leadingIcon: icon,
        label: labelWidget,
        selectable: widget.selectable,
        selected: isSelected,
        selectedColor: widget.selectedColor,
        onSelect: widget.selectable
            ? () {
                setState(() {
                  _selectedNodeId = id;
                });
                if (widget.onSelect != null) {
                  final eventContext = widget.context.createChildContext(
                    variables: {'event': node},
                  );
                  widget.context.actionHandler
                      .execute(widget.onSelect!, eventContext);
                }
              }
            : null,
        onExpansionChanged: (expanded) {
          final action = expanded ? widget.onExpand : widget.onCollapse;
          if (action != null) {
            final eventContext = widget.context.createChildContext(
              variables: {'event': node},
            );
            widget.context.actionHandler.execute(action, eventContext);
          }
        },
        childrenBuilder: () => _TreeView(
          nodes: children,
          expandAll: widget.expandAll,
          expandable: widget.expandable,
          showLines: widget.showLines,
          selectable: widget.selectable,
          indentation: widget.indentation,
          itemPadding: widget.itemPadding,
          itemTemplate: widget.itemTemplate,
          lineColor: widget.lineColor,
          selectedColor: widget.selectedColor,
          onSelect: widget.onSelect,
          onExpand: widget.onExpand,
          onCollapse: widget.onCollapse,
          context: widget.context,
          depth: widget.depth + 1,
        ),
      );
    } else if (hasChildren && !widget.expandable) {
      // Non-expandable node with children - show flat with children visible
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: widget.selectable
                ? () {
                    setState(() {
                      _selectedNodeId = id;
                    });
                    if (widget.onSelect != null) {
                      final eventContext = widget.context.createChildContext(
                        variables: {'event': node},
                      );
                      widget.context.actionHandler.execute(
                        widget.onSelect!,
                        eventContext,
                      );
                    }
                  }
                : null,
            child: Padding(
              padding: EdgeInsets.only(
                left: widget.indentation * widget.depth + 16,
                top: 8,
                bottom: 8,
                right: 16,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child:
                          Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  Flexible(child: labelWidget),
                ],
              ),
            ),
          ),
          _TreeView(
            nodes: children,
            expandAll: widget.expandAll,
            expandable: widget.expandable,
            showLines: widget.showLines,
            selectable: widget.selectable,
            indentation: widget.indentation,
            itemPadding: widget.itemPadding,
            itemTemplate: widget.itemTemplate,
            lineColor: widget.lineColor,
            selectedColor: widget.selectedColor,
            onSelect: widget.onSelect,
            onExpand: widget.onExpand,
            onCollapse: widget.onCollapse,
            context: widget.context,
            depth: widget.depth + 1,
          ),
        ],
      );
    } else {
      // Leaf node — mirror `_ExpandableNode`'s padding/row so siblings at
      // the same depth align regardless of whether a neighbouring node is
      // expandable. The chevron slot is reserved with an empty SizedBox
      // so labels line up exactly under expandable rows.
      return InkWell(
        onTap: widget.selectable
            ? () {
                setState(() {
                  _selectedNodeId = id;
                });
                if (widget.onSelect != null) {
                  final eventContext = widget.context.createChildContext(
                    variables: {'event': node},
                  );
                  widget.context.actionHandler.execute(
                    widget.onSelect!,
                    eventContext,
                  );
                }
              }
            : null,
        child: Container(
          decoration: isSelected
              ? BoxDecoration(
                  color: widget.selectedColor,
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          padding: EdgeInsets.only(
            left: widget.indentation * widget.depth + widget.itemPadding.left,
            right: widget.itemPadding.right,
            top: widget.itemPadding.top,
            bottom: widget.itemPadding.bottom,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Empty slot so leaf labels align with expandable siblings
              // at the same depth.
              const SizedBox(width: 20),
              if (icon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              Flexible(child: labelWidget),
            ],
          ),
        ),
      );
    }
  }

  IconData _parseIcon(String iconName) => resolveIconData(iconName);
}

/// Expandable tree node rendered as a compact file-explorer row: a
/// chevron toggles the children, everything sits in a plain Column so
/// the expanded subtree appears directly below the node (never beside it).
class _ExpandableNode extends StatefulWidget {
  const _ExpandableNode({
    super.key,
    required this.initiallyExpanded,
    required this.indentationLeft,
    required this.itemPadding,
    required this.leadingIcon,
    required this.label,
    required this.selectable,
    required this.selected,
    required this.selectedColor,
    required this.onSelect,
    required this.onExpansionChanged,
    required this.childrenBuilder,
  });

  final bool initiallyExpanded;
  final double indentationLeft;
  final EdgeInsets itemPadding;
  final IconData? leadingIcon;
  final Widget label;
  final bool selectable;
  final bool selected;
  final Color selectedColor;
  final VoidCallback? onSelect;
  final ValueChanged<bool> onExpansionChanged;
  final Widget Function() childrenBuilder;

  @override
  State<_ExpandableNode> createState() => _ExpandableNodeState();
}

class _ExpandableNodeState extends State<_ExpandableNode> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpansionChanged(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: () {
        _toggle();
        widget.onSelect?.call();
      },
      child: Container(
        padding: EdgeInsets.only(
          left: widget.indentationLeft + widget.itemPadding.left,
          right: widget.itemPadding.right,
          top: widget.itemPadding.top,
          bottom: widget.itemPadding.bottom,
        ),
        decoration: widget.selected
            ? BoxDecoration(
                color: widget.selectedColor,
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              child: Icon(
                _expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            if (widget.leadingIcon != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(widget.leadingIcon,
                    size: 18, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            Flexible(child: widget.label),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (_expanded) widget.childrenBuilder(),
      ],
    );
  }
}

