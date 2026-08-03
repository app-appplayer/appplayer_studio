import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `kanban` (spec §10.30).
///
/// The pieces for a composition exist (`grid` + `draggable` + `dragTarget`),
/// and that composition is where the work actually is: drop targets are the
/// **gaps between cards** rather than the cards, and a drop must report where
/// in the destination the card landed. Authors composing this get a board that
/// looks right and reorders wrongly.
///
/// The widget owns presentation and gesture; it does not own the move.
/// `onCardMove` reports intent and the author's action decides, so a
/// server-rejected move is not silently already applied on screen.
class KanbanFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final columns =
        context.resolve<List<dynamic>?>(properties['columns']) ?? const [];
    final itemTemplate = properties['itemTemplate'] as Map<String, dynamic>?;
    final itemKey = context.resolve<String?>(properties['itemKey']) ?? 'id';
    final draggable = context.resolve<bool?>(properties['draggable']) ?? true;
    final optimistic = context.resolve<bool?>(properties['optimistic']) ?? false;
    final columnWidth =
        context.resolve<num?>(properties['columnWidth'])?.toDouble() ?? 280.0;
    final onCardMove = properties['onCardMove'] as Map<String, dynamic>?;
    final onCardClick = properties['onCardClick'] as Map<String, dynamic>?;

    if (itemTemplate == null) return const SizedBox.shrink();

    final parsed = [
      for (final raw in columns)
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];

    return _Board(
      columns: parsed,
      columnWidth: columnWidth,
      draggable: draggable,
      optimistic: optimistic,
      itemKey: itemKey,
      buildCard: (item) => context.renderer.renderWidget(
        itemTemplate,
        context.createChildContext(variables: {'item': item}),
      ),
      onMove: (item, fromColumn, fromIndex, toColumn, toIndex) {
        if (onCardMove == null) return;
        context.actionHandler.execute(
          onCardMove,
          context.createChildContext(
            variables: {
              'event': {
                'item': item,
                'from': {'column': fromColumn, 'index': fromIndex},
                // The destination index matters: a board without ordering is
                // a list of columns.
                'to': {'column': toColumn, 'index': toIndex},
                'type': 'cardMove',
              },
            },
          ),
        );
      },
      onClick: (item) {
        if (onCardClick == null) return;
        context.actionHandler.execute(
          onCardClick,
          context.createChildContext(
            variables: {
              'event': {'item': item, 'type': 'cardClick'},
            },
          ),
        );
      },
    );
  }
}

typedef _CardBuilder = Widget Function(Map<String, dynamic> item);
typedef _MoveCallback = void Function(
  Map<String, dynamic> item,
  String fromColumn,
  int fromIndex,
  String toColumn,
  int toIndex,
);

class _Board extends StatefulWidget {
  const _Board({
    required this.columns,
    required this.columnWidth,
    required this.draggable,
    required this.optimistic,
    required this.itemKey,
    required this.buildCard,
    required this.onMove,
    required this.onClick,
  });

  final List<Map<String, dynamic>> columns;
  final double columnWidth;
  final bool draggable;
  final bool optimistic;
  final String itemKey;
  final _CardBuilder buildCard;
  final _MoveCallback onMove;
  final void Function(Map<String, dynamic>) onClick;

  @override
  State<_Board> createState() => _BoardState();
}

class _BoardState extends State<_Board> {
  late List<Map<String, dynamic>> _columns = _copy(widget.columns);

  @override
  void didUpdateWidget(_Board old) {
    super.didUpdateWidget(old);
    // Without optimistic moves the incoming data is the truth; with them the
    // local arrangement stands until the next rebuild replaces it.
    if (old.columns != widget.columns) _columns = _copy(widget.columns);
  }

  static List<Map<String, dynamic>> _copy(List<Map<String, dynamic>> src) => [
        for (final c in src)
          {
            ...c,
            'items': [
              for (final i in (c['items'] as List? ?? const []))
                if (i is Map) Map<String, dynamic>.from(i),
            ],
          },
      ];

  List<Map<String, dynamic>> _itemsOf(int column) =>
      (_columns[column]['items'] as List).cast<Map<String, dynamic>>();

  bool _atLimit(int column) {
    final limit = _columns[column]['limit'];
    return limit is num && _itemsOf(column).length >= limit;
  }

  void _drop(_DragPayload payload, int toColumn, int toIndex) {
    final fromColumn = payload.column;
    final fromIndex = payload.index;
    if (fromColumn == toColumn && (toIndex == fromIndex || toIndex == fromIndex + 1)) {
      return; // dropped where it already is
    }
    // Refused at the gesture rather than after the fact.
    if (fromColumn != toColumn && _atLimit(toColumn)) return;

    final item = payload.item;
    if (widget.optimistic) {
      setState(() {
        _itemsOf(fromColumn).removeAt(fromIndex);
        final adjusted =
            fromColumn == toColumn && fromIndex < toIndex ? toIndex - 1 : toIndex;
        _itemsOf(toColumn).insert(adjusted.clamp(0, _itemsOf(toColumn).length), item);
      });
    }
    widget.onMove(
      item,
      _columns[fromColumn]['key']?.toString() ?? '',
      fromIndex,
      _columns[toColumn]['key']?.toString() ?? '',
      toIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The board scrolls sideways through its columns; each column scrolls
    // through its own cards. Without the second axis a column stacked every
    // card it was given into a fixed-height `Column` and overflowed the
    // moment a board carried more than a screenful — which is every board
    // past its first week. `IntrinsicHeight` is gone with it: it sized the
    // row to the tallest column, which is unbounded by construction.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        height: double.infinity,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < _columns.length; c++)
              SizedBox(
                width: widget.columnWidth,
                child: _Column(
                  title: _columns[c]['title']?.toString() ?? '',
                  count: _itemsOf(c).length,
                  limit: (_columns[c]['limit'] as num?)?.toInt(),
                  children: [
                    // A gap before every card and one after the last: the drop
                    // targets are the spaces, which is what makes the
                    // destination index meaningful.
                    for (var i = 0; i <= _itemsOf(c).length; i++) ...[
                      _Gap(
                        onAccept: (p) => _drop(p, c, i),
                        accepts: widget.draggable,
                      ),
                      if (i < _itemsOf(c).length)
                        _Card(
                          payload: _DragPayload(_itemsOf(c)[i], c, i),
                          draggable: widget.draggable,
                          onTap: () => widget.onClick(_itemsOf(c)[i]),
                          child: widget.buildCard(_itemsOf(c)[i]),
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _DragPayload {
  const _DragPayload(this.item, this.column, this.index);
  final Map<String, dynamic> item;
  final int column;
  final int index;
}

class _Column extends StatelessWidget {
  const _Column({
    required this.title,
    required this.count,
    required this.children,
    this.limit,
  });

  final String title;
  final int count;
  final int? limit;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Text(limit == null ? '$count' : '$count / $limit'),
              ],
            ),
          ),
          // The header stays put and the cards scroll under it: a column with
          // eighty cards is normal, and losing the title to reach the last
          // one is not.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Gap extends StatefulWidget {
  const _Gap({required this.onAccept, required this.accepts});

  final void Function(_DragPayload) onAccept;
  final bool accepts;

  @override
  State<_Gap> createState() => _GapState();
}

class _GapState extends State<_Gap> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.accepts) return const SizedBox(height: 4);
    return DragTarget<_DragPayload>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hovering = true);
        return true;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (d) {
        setState(() => _hovering = false);
        widget.onAccept(d.data);
      },
      builder: (_, __, ___) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: _hovering ? 24 : 8,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: _hovering
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.payload,
    required this.draggable,
    required this.onTap,
    required this.child,
  });

  final _DragPayload payload;
  final bool draggable;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final card = GestureDetector(onTap: onTap, child: child);
    if (!draggable) return card;
    return Draggable<_DragPayload>(
      data: payload,
      feedback: Material(
        elevation: 6,
        child: SizedBox(width: 260, child: child),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }
}
