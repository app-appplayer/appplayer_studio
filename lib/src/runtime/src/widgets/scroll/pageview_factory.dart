import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for PageView widgets
class PageViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.9.4 canonical `direction`; `scrollDirection` kept as legacy alias.
    final scrollDirection =
        _parseAxis(properties['direction'] ?? properties['scrollDirection']) ??
            Axis.horizontal;
    final reverse = properties['reverse'] as bool? ?? false;
    final pageSnapping = properties['pageSnapping'] as bool? ?? true;
    final allowImplicitScrolling =
        properties['allowImplicitScrolling'] as bool? ?? false;
    final padEnds = properties['padEnds'] as bool? ?? true;
    final clipBehavior =
        _parseClip(properties['clipBehavior']) ?? Clip.hardEdge;

    // Spec § pageView v1.3 — `initialPage`, `loop`, `scrollPhysics`.
    final initialPage =
        (context.resolve(properties['initialPage']) as num?)?.toInt() ?? 0;
    final loop = context.resolve(properties['loop']) as bool? ?? false;
    final physics =
        _parsePhysics(context.resolve(properties['scrollPhysics']));

    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    final children = childrenDef
            ?.map((child) => context.buildWidget(child as Map<String, dynamic>))
            .toList() ??
        [];

    // Spec §2.9.4 canonical `onPageChanged`. `onChange` accepted as alias.
    final onPageChanged =
        (properties['onPageChanged'] ?? properties['onChange'])
            as Map<String, dynamic>?;

    final controller = PageController(initialPage: initialPage);
    final onPageHandler = onPageChanged != null
        ? (int index) {
            final eventContext = context.createChildContext(
              variables: {
                'event': {'page': index, 'index': index, 'type': 'pageChanged'},
              },
            );
            context.actionHandler.execute(onPageChanged, eventContext);
          }
        : null;

    final Widget pageView = loop && children.isNotEmpty
        ? PageView.builder(
            controller: controller,
            scrollDirection: scrollDirection,
            reverse: reverse,
            pageSnapping: pageSnapping,
            allowImplicitScrolling: allowImplicitScrolling,
            padEnds: padEnds,
            clipBehavior: clipBehavior,
            physics: physics,
            onPageChanged: onPageHandler,
            itemBuilder: (ctx, i) => children[i % children.length],
          )
        : PageView(
            controller: controller,
            scrollDirection: scrollDirection,
            reverse: reverse,
            pageSnapping: pageSnapping,
            allowImplicitScrolling: allowImplicitScrolling,
            padEnds: padEnds,
            clipBehavior: clipBehavior,
            physics: physics,
            onPageChanged: onPageHandler,
            children: children,
          );

    return applyCommonWrappers(pageView, properties, context);
  }

  ScrollPhysics? _parsePhysics(dynamic value) {
    switch (value) {
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      case 'neverScrollable':
        return const NeverScrollableScrollPhysics();
    }
    return null;
  }

  Axis? _parseAxis(String? value) {
    switch (value) {
      case 'horizontal':
        return Axis.horizontal;
      case 'vertical':
        return Axis.vertical;
      default:
        return null;
    }
  }

  Clip? _parseClip(String? value) {
    switch (value) {
      case 'none':
        return Clip.none;
      case 'hardEdge':
        return Clip.hardEdge;
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      default:
        return null;
    }
  }
}
