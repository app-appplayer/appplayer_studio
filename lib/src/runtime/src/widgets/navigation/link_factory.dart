import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for `link` (spec §2.8.13). Alias: `navLink`.
///
/// The `inkWell` + `text` + action composition most documents use today loses
/// the link role — assistive technology announces "button" — along with the
/// hover affordance and, for external destinations, the cue a user needs
/// before leaving the app.
class LinkFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final label = context.resolve<String?>(properties['label']) ?? '';
    final route = context.resolve<String?>(properties['route']);
    final url = context.resolve<String?>(properties['url']);
    final rawTarget = context.resolve<String?>(properties['target']);
    // `same` and `new` are the declared values; anything else is a hint the
    // host would not understand, so it falls back rather than travelling on.
    final target = rawTarget == 'same' ? 'same' : 'new';
    final underline = context.resolve<String?>(properties['underline']) ?? 'hover';
    final activeWhen = context.resolve<String?>(properties['activeWhen']);
    final onClick = actionOf(properties['onClick'], context);
    final child = properties['child'] as Map<String, dynamic>?;
    final icon = properties['icon'] == null
        ? null
        : resolveIconRef(context.resolve<Object?>(properties['icon']));

    // Exactly one destination: a link that could mean either is a link whose
    // destination the author did not decide.
    final active = activeWhen != null && route != null && activeWhen == route;

    void activate() {
      if (url != null && url.isNotEmpty) {
        context.actionHandler.execute({
          'type': 'navigation',
          'action': 'openUrl',
          'url': url,
          'target': target,
        }, context);
      } else if (route != null && route.isNotEmpty) {
        context.actionHandler.execute({
          'type': 'navigation',
          'action': 'push',
          'route': route,
          if (properties['params'] != null) 'params': properties['params'],
        }, context);
      }
      if (onClick != null) {
        context.actionHandler.execute(
          onClick,
          context.createChildContext(
            variables: {
              'event': {'value': url ?? route, 'type': 'click'},
            },
          ),
        );
      }
    }

    final content = child != null
        ? context.renderer.renderWidget(child, context)
        : null;

    return _Link(
      label: label,
      icon: icon,
      active: active,
      external: url != null && url.isNotEmpty,
      underline: underline,
      onTap: activate,
      child: content,
    );
  }
}

class _Link extends StatefulWidget {
  const _Link({
    required this.label,
    required this.active,
    required this.external,
    required this.underline,
    required this.onTap,
    this.child,
    this.icon,
  });

  final String label;
  final Widget? child;
  final IconData? icon;
  final bool active;
  final bool external;
  final String underline;
  final VoidCallback onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showUnderline = widget.underline == 'always' ||
        (widget.underline == 'hover' && _hovering);

    return Semantics(
      link: true, // the role a composed inkWell cannot claim
      selected: widget.active,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: widget.child ??
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 16, color: scheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: widget.active ? FontWeight.w600 : null,
                      decoration:
                          showUnderline ? TextDecoration.underline : null,
                    ),
                  ),
                  if (widget.external) ...[
                    const SizedBox(width: 2),
                    // The cue a user needs before leaving the app.
                    Icon(Icons.open_in_new, size: 12, color: scheme.primary),
                  ],
                ],
              ),
        ),
      ),
    );
  }
}
