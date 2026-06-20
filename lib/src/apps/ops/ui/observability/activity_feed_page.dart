// Live Activity Feed — streams [ActivityEvent]s from the bus into a
// scrolling timeline. PRD §FM-OBSERVE-03.
//
// Filters: kind chips + actor search. Auto-scroll pinned to the latest
// entry; user scrolling up unpins until they jump back to the bottom.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../observability/activity_event.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';

class ActivityFeedPage extends ConsumerStatefulWidget {
  const ActivityFeedPage({super.key});

  @override
  ConsumerState<ActivityFeedPage> createState() => _ActivityFeedPageState();
}

class _ActivityFeedPageState extends ConsumerState<ActivityFeedPage> {
  final Set<ActivityKind> _kindFilter = <ActivityKind>{};
  String _actorFilter = '';
  final _scroll = ScrollController();
  bool _autoFollow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      // If the user scrolls more than 80px from the bottom, stop auto-pinning.
      final atBottom =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      if (_autoFollow != atBottom) {
        setState(() => _autoFollow = atBottom);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final obs = ref.watch(observabilityProvider);
    final eventsAsync = ref.watch(activitySnapshotProvider);
    var events = eventsAsync.maybeWhen(
      data: (e) => e,
      orElse: () => obs.bus.recent,
    );
    if (_kindFilter.isNotEmpty) {
      events = [
        for (final e in events)
          if (_kindFilter.contains(e.kind)) e,
      ];
    }
    if (_actorFilter.isNotEmpty) {
      final f = _actorFilter.toLowerCase();
      events = [
        for (final e in events)
          if (e.actor.toLowerCase().contains(f) ||
              e.headline.toLowerCase().contains(f))
            e,
      ];
    }

    if (_autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Live activity',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (!_autoFollow)
                TextButton.icon(
                  icon: const Icon(Icons.vertical_align_bottom, size: 14),
                  label: const Text('Jump to latest'),
                  onPressed: () {
                    setState(() => _autoFollow = true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          _Filters(
            selected: _kindFilter,
            onToggle:
                (k) => setState(() {
                  if (!_kindFilter.add(k)) _kindFilter.remove(k);
                }),
            actor: _actorFilter,
            onActorChanged: (s) => setState(() => _actorFilter = s),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: OpsColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: OpsColors.border),
              ),
              child:
                  events.isEmpty
                      ? const EmptyState(
                        icon: Icons.bolt_outlined,
                        headline: 'Waiting for activity',
                        hint:
                            'Trigger a tool, send a chat, or connect a client. The bus emits agent asks · tool dispatches · MCP inbound calls live.',
                        compact: true,
                      )
                      : ListView.builder(
                        controller: _scroll,
                        itemCount: events.length,
                        itemBuilder:
                            (ctx, i) => _FeedRow(
                              event: events[i],
                              isLast: i == events.length - 1,
                            ),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.selected,
    required this.onToggle,
    required this.actor,
    required this.onActorChanged,
  });
  final Set<ActivityKind> selected;
  final ValueChanged<ActivityKind> onToggle;
  final String actor;
  final ValueChanged<String> onActorChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final k in ActivityKind.values)
          FilterChip(
            label: Text(k.name, style: const TextStyle(fontSize: 11)),
            selected: selected.contains(k),
            onSelected: (_) => onToggle(k),
            visualDensity: VisualDensity.compact,
          ),
        SizedBox(
          width: 200,
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Filter by actor / headline…',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 14),
            ),
            onChanged: onActorChanged,
          ),
        ),
      ],
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.event, required this.isLast});
  final ActivityEvent event;
  final bool isLast;
  @override
  Widget build(BuildContext context) {
    final color = switch (event.severity) {
      ActivitySeverity.error => OpsColors.danger,
      ActivitySeverity.warn => OpsColors.warn,
      ActivitySeverity.info => OpsColors.text2,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border:
            isLast ? null : Border(bottom: BorderSide(color: OpsColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              _fmtTime(event.ts),
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 11,
                color: OpsColors.text3,
              ),
            ),
          ),
          SizedBox(
            width: 100,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: OpsColors.surface2,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                event.kind.name,
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 10,
                  color: OpsColors.text2,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: Text(
              event.actor,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 11,
                color: OpsColors.text2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              event.headline,
              style: TextStyle(
                fontFamily: OpsType.sans,
                fontSize: 12,
                color: color,
              ),
            ),
          ),
          if (event.tokensIn != null || event.tokensOut != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${event.tokensIn ?? 0}→${event.tokensOut ?? 0} tok',
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 10,
                  color: OpsColors.text3,
                ),
              ),
            ),
          if (event.durationMs != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${event.durationMs}ms',
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 10,
                  color: OpsColors.text3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
