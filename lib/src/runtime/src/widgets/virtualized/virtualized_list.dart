import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../../utils/mcp_logger.dart';

/// Virtualized list widget for performance optimization
/// according to MCP UI DSL v1.0 specification
class VirtualizedListWidget extends StatefulWidget {
  final List<dynamic> items;
  final Widget Function(BuildContext, dynamic, int) itemBuilder;
  final double? itemHeight;
  final int cacheExtent;
  final int virtualizeThreshold;
  final Axis scrollDirection;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? padding;
  final bool shrinkWrap;
  final ScrollController? controller;
  final bool reverse;
  final bool primary;
  final String? restorationId;

  const VirtualizedListWidget({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.itemHeight,
    this.cacheExtent = 250,
    this.virtualizeThreshold = 100,
    this.scrollDirection = Axis.vertical,
    this.physics,
    this.padding,
    this.shrinkWrap = false,
    this.controller,
    this.reverse = false,
    bool? primary,
    this.restorationId,
  }) : primary = primary ?? false;

  @override
  State<VirtualizedListWidget> createState() => _VirtualizedListWidgetState();
}

class _VirtualizedListWidgetState extends State<VirtualizedListWidget> {
  final MCPLogger _logger = MCPLogger('VirtualizedList');
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = widget.controller ?? ScrollController();

    _logger.debug(
        'Initializing VirtualizedList with ${widget.items.length} items');
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use virtualization for lists larger than threshold
    if (widget.items.length > widget.virtualizeThreshold) {
      _logger.debug('Using virtualized list for ${widget.items.length} items');
      return _buildVirtualizedList();
    } else {
      _logger.debug('Using regular list for ${widget.items.length} items');
      return _buildRegularList();
    }
  }

  /// Build virtualized list using ListView.builder
  Widget _buildVirtualizedList() {
    return ListView.builder(
      controller: _scrollController,
      scrollDirection: widget.scrollDirection,
      reverse: widget.reverse,
      primary: widget.primary,
      physics: widget.physics,
      shrinkWrap: widget.shrinkWrap,
      padding: widget.padding,
      itemExtent: widget
          .itemHeight, // Improves performance if all items have same height
      cacheExtent: widget.cacheExtent.toDouble(),
      restorationId: widget.restorationId,
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        return widget.itemBuilder(context, widget.items[index], index);
      },
    );
  }

  /// Build regular list for small item counts
  Widget _buildRegularList() {
    final children = widget.items.asMap().entries.map((entry) {
      return widget.itemBuilder(context, entry.value, entry.key);
    }).toList();

    if (widget.scrollDirection == Axis.vertical) {
      return SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        padding: widget.padding,
        physics: widget.physics,
        primary: widget.primary,
        restorationId: widget.restorationId,
        child: Column(
          mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          children: children,
        ),
      );
    } else {
      return SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        padding: widget.padding,
        physics: widget.physics,
        primary: widget.primary,
        restorationId: widget.restorationId,
        child: Row(
          mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          children: children,
        ),
      );
    }
  }
}

/// Virtualized grid widget for performance optimization
class VirtualizedGridWidget extends StatefulWidget {
  final List<dynamic> items;
  final Widget Function(BuildContext, dynamic, int) itemBuilder;
  final int crossAxisCount;
  final double? childAspectRatio;
  final double? crossAxisSpacing;
  final double? mainAxisSpacing;
  final int cacheExtent;
  final int virtualizeThreshold;
  final Axis scrollDirection;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? padding;
  final bool shrinkWrap;
  final ScrollController? controller;
  final bool reverse;
  final bool primary;

  const VirtualizedGridWidget({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.crossAxisCount,
    this.childAspectRatio = 1.0,
    this.crossAxisSpacing = 0.0,
    this.mainAxisSpacing = 0.0,
    this.cacheExtent = 250,
    this.virtualizeThreshold = 50,
    this.scrollDirection = Axis.vertical,
    this.physics,
    this.padding,
    this.shrinkWrap = false,
    this.controller,
    this.reverse = false,
    bool? primary,
  }) : primary = primary ?? false;

  @override
  State<VirtualizedGridWidget> createState() => _VirtualizedGridWidgetState();
}

class _VirtualizedGridWidgetState extends State<VirtualizedGridWidget> {
  final MCPLogger _logger = MCPLogger('VirtualizedGrid');
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = widget.controller ?? ScrollController();

    _logger.debug(
        'Initializing VirtualizedGrid with ${widget.items.length} items');
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use virtualization for grids larger than threshold
    if (widget.items.length > widget.virtualizeThreshold) {
      _logger.debug('Using virtualized grid for ${widget.items.length} items');
      return _buildVirtualizedGrid();
    } else {
      _logger.debug('Using regular grid for ${widget.items.length} items');
      return _buildRegularGrid();
    }
  }

  /// Build virtualized grid using GridView.builder
  Widget _buildVirtualizedGrid() {
    return GridView.builder(
      controller: _scrollController,
      scrollDirection: widget.scrollDirection,
      reverse: widget.reverse,
      primary: widget.primary,
      physics: widget.physics,
      shrinkWrap: widget.shrinkWrap,
      padding: widget.padding,
      cacheExtent: widget.cacheExtent.toDouble(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.crossAxisCount,
        childAspectRatio: widget.childAspectRatio ?? 1.0,
        crossAxisSpacing: widget.crossAxisSpacing ?? 0.0,
        mainAxisSpacing: widget.mainAxisSpacing ?? 0.0,
      ),
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        return widget.itemBuilder(context, widget.items[index], index);
      },
    );
  }

  /// Build regular grid for small item counts
  Widget _buildRegularGrid() {
    final children = widget.items.asMap().entries.map((entry) {
      return widget.itemBuilder(context, entry.value, entry.key);
    }).toList();

    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: widget.scrollDirection,
      reverse: widget.reverse,
      padding: widget.padding,
      physics: widget.physics,
      primary: widget.primary,
      child: Wrap(
        direction: widget.scrollDirection,
        spacing: widget.crossAxisSpacing ?? 0.0,
        runSpacing: widget.mainAxisSpacing ?? 0.0,
        children: children,
      ),
    );
  }
}

/// Extension to integrate virtualized lists with existing list widgets
extension VirtualizationExtension on RenderContext {
  /// Check if list should be virtualized based on item count
  bool shouldVirtualize(int itemCount, {int? threshold}) {
    final virtualizeThreshold = threshold ?? 100;
    return itemCount > virtualizeThreshold;
  }

  /// Create virtualized list widget
  Widget createVirtualizedList({
    required List<dynamic> items,
    required Widget Function(BuildContext, dynamic, int) itemBuilder,
    double? itemHeight,
    int cacheExtent = 250,
    int virtualizeThreshold = 100,
    Axis scrollDirection = Axis.vertical,
    ScrollPhysics? physics,
    EdgeInsetsGeometry? padding,
    bool shrinkWrap = false,
    ScrollController? controller,
    bool reverse = false,
    bool? primary,
  }) {
    return VirtualizedListWidget(
      items: items,
      itemBuilder: itemBuilder,
      itemHeight: itemHeight,
      cacheExtent: cacheExtent,
      virtualizeThreshold: virtualizeThreshold,
      scrollDirection: scrollDirection,
      physics: physics,
      padding: padding,
      shrinkWrap: shrinkWrap,
      controller: controller,
      reverse: reverse,
      primary: primary ?? false,
    );
  }

  /// Create virtualized grid widget
  Widget createVirtualizedGrid({
    required List<dynamic> items,
    required Widget Function(BuildContext, dynamic, int) itemBuilder,
    required int crossAxisCount,
    double? childAspectRatio,
    double? crossAxisSpacing,
    double? mainAxisSpacing,
    int cacheExtent = 250,
    int virtualizeThreshold = 50,
    Axis scrollDirection = Axis.vertical,
    ScrollPhysics? physics,
    EdgeInsetsGeometry? padding,
    bool shrinkWrap = false,
    ScrollController? controller,
    bool reverse = false,
    bool? primary,
  }) {
    return VirtualizedGridWidget(
      items: items,
      itemBuilder: itemBuilder,
      crossAxisCount: crossAxisCount,
      childAspectRatio: childAspectRatio,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      cacheExtent: cacheExtent,
      virtualizeThreshold: virtualizeThreshold,
      scrollDirection: scrollDirection,
      physics: physics,
      padding: padding,
      shrinkWrap: shrinkWrap,
      controller: controller,
      reverse: reverse,
      primary: primary ?? false,
    );
  }
}
