import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';
import '../../utils/mcp_logger.dart';

/// Factory for creating SingleChildScrollView widgets
class ScrollViewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Get scroll direction (spec v1.0: 'direction', legacy: 'scrollDirection')
    final scrollDirectionStr =
        readEnum(properties['direction'] ?? properties['scrollDirection'], context);
    final scrollDirection =
        scrollDirectionStr == 'horizontal' ? Axis.horizontal : Axis.vertical;

    // Get other properties
    final reverse = boolOf(properties['reverse'], context) ?? false;
    final padding = edgeInsetsOf(properties['padding'], context);
    final primary = boolOf(properties['primary'], context);
    // `scrollPhysics` (canonical) replaces
    // the legacy `physics` key. Both accepted for backward compat.
    final physics = _parseScrollPhysics(
        readEnum(properties['scrollPhysics'] ?? properties['physics'], context));

    // Sliver mode: `slivers` is a distinct layout mode, not a second
    // spelling of `children`. It used to be laid out as ordinary children on
    // the grounds that a `SingleChildScrollView` cannot host slivers — which
    // meant a `sliverAppBar` reached the widget registry, found no factory
    // there, and drew an unknown-type box in the middle of the page. The
    // viewport that *can* host them is `CustomScrollView`, so sliver mode
    // builds one.
    final sliverDefs = properties['slivers'];
    if (sliverDefs is List && sliverDefs.isNotEmpty) {
      return _buildSliverMode(
        sliverDefs,
        context,
        scrollDirection: scrollDirection,
        reverse: reverse,
        physics: physics,
        primary: primary,
        padding: padding,
      );
    }

    // Linear mode takes `child` or `children`; `children` are wrapped in an
    // implicit row/column along the scroll direction.
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final childrenDef = properties['children'] as List<dynamic>?;
    if (childDef != null) {
      child = context.renderer.renderWidget(childDef, context);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      final built = <Widget>[
        for (final def in childrenDef)
          if (def is Map<String, dynamic>)
            context.renderer.renderWidget(def, context),
      ];
      child = scrollDirection == Axis.horizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: built)
          : Column(mainAxisSize: MainAxisSize.min, children: built);
    }

    final scrollView = SingleChildScrollView(
      scrollDirection: scrollDirection,
      reverse: reverse,
      padding: padding,
      primary: primary,
      physics: physics,
      child: child,
    );

    // Ensure scrollview has proper constraints in test environment
    // This prevents viewport assertion errors during widget tree construction
    if (primary != false) {
      return scrollView;
    }

    // Wrap in a constrained box to ensure stable rendering
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedHeight && constraints.hasBoundedWidth) {
          return scrollView;
        }
        // Provide default constraints for unbounded contexts
        return SizedBox(
          width: constraints.hasBoundedWidth ? null : double.infinity,
          height: constraints.hasBoundedHeight
              ? null
              : MediaQuery.of(context).size.height,
          child: scrollView,
        );
      },
    );
  }

  /// Builds the `slivers` form into a [CustomScrollView].
  ///
  /// A sliver shape the spec does not define is reported in place rather than
  /// dropped.
  Widget _buildSliverMode(
    List<dynamic> defs,
    RenderContext context, {
    required Axis scrollDirection,
    required bool reverse,
    required ScrollPhysics? physics,
    required bool? primary,
    required EdgeInsets? padding,
  }) {
    final slivers = <Widget>[
      for (final def in defs)
        if (def is Map<String, dynamic>) _buildSliver(def, context),
    ];

    final viewport = CustomScrollView(
      scrollDirection: scrollDirection,
      reverse: reverse,
      physics: physics,
      primary: primary,
      slivers: [
        if (padding != null)
          SliverPadding(
            padding: padding,
            sliver: SliverMainAxisGroup(slivers: slivers),
          )
        else
          ...slivers,
      ],
    );

    // Both modes take the same unbounded-parent fallback: a `CustomScrollView`
    // in an unbounded slot lays out nothing, silently.
    return _boundedOrFallback(viewport, scrollDirection);
  }

  /// Gives [child] a finite extent along [axis] when the parent supplies none.
  Widget _boundedOrFallback(Widget child, Axis axis) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = axis == Axis.horizontal
            ? constraints.hasBoundedWidth
            : constraints.hasBoundedHeight;
        if (bounded) return child;
        return SizedBox(
          width: constraints.hasBoundedWidth ? null : MediaQuery.of(context).size.width,
          height:
              constraints.hasBoundedHeight ? null : MediaQuery.of(context).size.height,
          child: child,
        );
      },
    );
  }

  Widget _buildSliver(Map<String, dynamic> def, RenderContext context) {
    final type = def['type'];
    switch (type) {
      case 'sliverAppBar':
        return _sliverAppBar(def, context);
      case 'sliverPersistentHeader':
        return _sliverPersistentHeader(def, context);
      case 'sliverList':
        return SliverList(
          delegate: _sliverChildren(def, context),
        );
      case 'sliverFixedExtentList':
        return SliverFixedExtentList(
          itemExtent: dimensionOf(def['itemExtent'], context) ?? 48.0,
          delegate: _sliverChildren(def, context),
        );
      case 'sliverGrid':
        final columns =
            (context.resolve<num?>(def['columns']) ?? 2).toInt().clamp(1, 1000);
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing:
                (context.resolve<num?>(def['mainAxisSpacing']) ?? 0).toDouble(),
            crossAxisSpacing:
                (context.resolve<num?>(def['crossAxisSpacing']) ?? 0).toDouble(),
            childAspectRatio:
                (context.resolve<num?>(def['itemAspectRatio']) ?? 1).toDouble(),
          ),
          delegate: _sliverChildren(def, context),
        );
      default:
        // Worded with the renderer's marker so failure-watching surfaces see it.
        return SliverToBoxAdapter(
          child: context.renderer.renderWidget(
            <String, dynamic>{
              'type': 'text',
              'content': 'Error rendering scrollView: unknown sliver type: '
                  '$type',
            },
            context,
          ),
        );
    }
  }

  Widget _sliverAppBar(Map<String, dynamic> def, RenderContext context) {
    final titleDef = def['title'] as Map<String, dynamic>?;
    final flexibleDef = def['flexibleSpace'] as Map<String, dynamic>?;
    final backgroundDef = def['background'] as Map<String, dynamic>?;

    // `flexibleSpace` is the whole hero area; `background` is the layer behind
    // the collapsing title. A document may give either, and giving `background`
    // alone is the common case (the documented example does), so it is wrapped
    // in the bar that knows how to collapse it rather than dropped for not
    // being a `flexibleSpace`.
    Widget? flexibleSpace;
    if (flexibleDef != null) {
      flexibleSpace = context.renderer.renderWidget(flexibleDef, context);
    } else if (backgroundDef != null) {
      flexibleSpace = FlexibleSpaceBar(
        background: context.renderer.renderWidget(backgroundDef, context),
      );
    }

    return SliverAppBar(
      // The bar's own surface, which is what remains once the hero has faded
      // out; a `title` colour chosen against the hero does not read against it.
      backgroundColor:
          parseColor(context.resolve(def['backgroundColor']), context),
      foregroundColor:
          parseColor(context.resolve(def['foregroundColor']), context),
      title: titleDef == null
          ? null
          : context.renderer.renderWidget(titleDef, context),
      expandedHeight: dimensionOf(def['expandedHeight'], context),
      pinned: boolOf(def['pinned'], context) ?? false,
      floating: boolOf(def['floating'], context) ?? false,
      snap: (boolOf(def['snap'], context) ?? false) &&
          (boolOf(def['floating'], context) ?? false),
      stretch: boolOf(def['stretch'], context) ?? false,
      elevation: dimensionOf(def['elevation'], context),
      flexibleSpace: flexibleSpace,
    );
  }

  Widget _sliverPersistentHeader(
      Map<String, dynamic> def, RenderContext context) {
    final childDef = def['child'] as Map<String, dynamic>?;
    final minExtent = dimensionOf(def['minExtent'], context) ?? 48.0;
    final maxExtent = dimensionOf(def['maxExtent'], context) ?? minExtent;
    return SliverPersistentHeader(
      pinned: boolOf(def['pinned'], context) ?? false,
      floating: boolOf(def['floating'], context) ?? false,
      delegate: _HeaderDelegate(
        minHeight: minExtent,
        maxHeight: maxExtent < minExtent ? minExtent : maxExtent,
        child: childDef == null
            ? const SizedBox.shrink()
            : context.renderer.renderWidget(childDef, context),
      ),
    );
  }

  /// The `children` / `items` + `itemTemplate` pair the list widgets already
  /// take, so a section inside a scroll view is written the same way as
  /// a standalone list.
  SliverChildDelegate _sliverChildren(
      Map<String, dynamic> def, RenderContext context) {
    final children = context.resolve(def['children']);
    if (children is List) {
      return SliverChildListDelegate([
        for (final child in children)
          if (child is Map<String, dynamic>)
            context.renderer.renderWidget(child, context),
      ]);
    }

    final template = def['itemTemplate'] as Map<String, dynamic>?;
    final resolved = context.resolve(def['items']);
    final items = resolved is List ? resolved : const <dynamic>[];

    // `items` holding widget nodes is drawn the way `children` is; without a
    // template there is nothing else it could mean. Widening, not narrowing
    // the accepted input.
    if (template == null && items.isNotEmpty) {
      final widgets = <Widget>[
        for (final item in items)
          if (item is Map<String, dynamic> && item['type'] is String)
            context.renderer.renderWidget(item, context),
      ];
      if (widgets.length == items.length) {
        return SliverChildListDelegate(widgets);
      }
      // Data rows with no template to render them through: nothing can be
      // drawn, so say so rather than leaving the section blank.
      MCPLogger('ScrollViewFactory').error(
        'sliver `items` has ${items.length} entr'
        '${items.length == 1 ? 'y' : 'ies'} and no `itemTemplate`, and they '
        'are not widget nodes — nothing was rendered for this section',
      );
      return SliverChildListDelegate(const <Widget>[]);
    }
    if (template == null || items.isEmpty) {
      return SliverChildListDelegate(const <Widget>[]);
    }
    return SliverChildBuilderDelegate(
      (buildContext, index) => context.renderer.renderWidget(
        template,
        context.createChildContext(variables: {
          'item': items[index],
          'index': index,
          'isFirst': index == 0,
          'isLast': index == items.length - 1,
          'isEven': index % 2 == 0,
          'isOdd': index % 2 == 1,
        }),
      ),
      childCount: items.length,
    );
  }

  ScrollPhysics? _parseScrollPhysics(String? value) {
    switch (value) {
      case 'never':
      case 'neverScrollable':
        return const NeverScrollableScrollPhysics();
      case 'always':
      case 'alwaysScrollable':
        return const AlwaysScrollableScrollPhysics();
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      default:
        return null;
    }
  }
}

/// Holds a `sliverPersistentHeader`'s child between its declared extents.
class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  _HeaderDelegate({
    required this.minHeight,
    required this.maxHeight,
    required this.child,
  });

  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => maxHeight;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox.expand(child: child);

  @override
  bool shouldRebuild(_HeaderDelegate oldDelegate) =>
      minHeight != oldDelegate.minHeight ||
      maxHeight != oldDelegate.maxHeight ||
      child != oldDelegate.child;
}
