import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for `accordion` (spec §2.4.22). Alias: `collapsible`.
///
/// Composing this from `conditional` + `inkWell` renders correctly and loses
/// two things the author cannot add back: the expand/collapse transition, and
/// the accessibility state a screen reader announces. A collapsed section that
/// is merely absent from the tree reads to assistive technology as content
/// that does not exist rather than content that is hidden — which is why the
/// panels stay in the tree here and collapse visually.
class AccordionFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final panels =
        context.resolve<List<dynamic>?>(properties['panels']) ?? const [];
    final allowMultiple =
        context.resolve<bool?>(properties['allowMultiple']) ?? false;
    final bordered = context.resolve<bool?>(properties['bordered']) ?? true;
    final expandedBinding = properties['expandedIds'] as String?;
    final onChange = properties['onChange'] as Map<String, dynamic>?;

    final expanded = <String>{
      ...?_expandedFrom(expandedBinding, properties, context),
      // A panel may declare its own initial state; the bound list wins when
      // both are present because it is the addressable one.
      if (expandedBinding == null)
        for (final p in panels)
          if (p is Map && p['expanded'] == true) p['id']?.toString() ?? '',
    }..remove('');

    void toggle(String id) {
      final next = Set<String>.from(expanded);
      if (next.contains(id)) {
        next.remove(id);
      } else {
        if (!allowMultiple) next.clear();
        next.add(id);
      }
      if (expandedBinding != null) {
        context.setValue(expandedBinding, next.toList());
      }
      if (onChange != null) {
        context.actionHandler.execute(
          onChange,
          context.createChildContext(
            variables: {
              'event': {'value': next.toList(), 'id': id, 'type': 'change'},
            },
          ),
        );
      }
    }

    return _Accordion(
      panels: [
        for (final raw in panels)
          if (raw is Map)
            _Panel(
              id: raw['id']?.toString() ?? '',
              title: raw['title']?.toString(),
              header: raw['header'] is Map
                  ? context.renderer.renderWidget(
                      Map<String, dynamic>.from(raw['header'] as Map), context)
                  : null,
              content: raw['content'] is Map
                  ? context.renderer.renderWidget(
                      Map<String, dynamic>.from(raw['content'] as Map), context)
                  : const SizedBox.shrink(),
              enabled: raw['enabled'] != false,
            ),
      ],
      expanded: expanded,
      bordered: bordered,
      onToggle: toggle,
      icon: context.resolve<String?>(properties['icon']),
    );
  }

  List<String>? _expandedFrom(
    String? binding,
    Map<String, dynamic> properties,
    RenderContext context,
  ) {
    if (binding == null) return null;
    final raw = context.getState(binding);
    return raw is List ? raw.map((e) => e.toString()).toList() : const [];
  }
}

class _Panel {
  const _Panel({
    required this.id,
    required this.content,
    required this.enabled,
    this.title,
    this.header,
  });

  final String id;
  final String? title;
  final Widget? header;
  final Widget content;
  final bool enabled;
}

class _Accordion extends StatelessWidget {
  const _Accordion({
    required this.panels,
    required this.expanded,
    required this.bordered,
    required this.onToggle,
    this.icon,
  });

  final List<_Panel> panels;
  final Set<String> expanded;
  final bool bordered;
  final ValueChanged<String> onToggle;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final panel in panels) ...[
          Semantics(
            // The state assistive technology needs, and the thing a
            // conditional-based composition cannot express.
            container: true,
            expanded: expanded.contains(panel.id),
            child: InkWell(
              onTap: panel.enabled ? () => onToggle(panel.id) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: panel.header ??
                          Text(
                            panel.title ?? '',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                    ),
                    AnimatedRotation(
                      turns: expanded.contains(panel.id) ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(width: double.infinity, child: panel.content),
            ),
            crossFadeState: expanded.contains(panel.id)
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
          if (bordered) const Divider(height: 1),
        ],
      ],
    );
  }
}
