import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for TabBar widgets
class TabBarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract tabs
    // Tolerant read: a bound path whose state holds a scalar (a server
    // response still loading, an author mid-edit) used to throw out of the
    // cast, and the renderer painted a red box over the whole tab strip.
    // Measured on a published build. An empty strip is what no data draws
    // anyway; a stack trace on screen is not.
    final tabsData = listOf(properties['tabs'], context) ?? const [];
    final tabs = tabsData.map<Tab>((tab) {
      if (tab is Map<String, dynamic>) {
        // A tab naming neither a label nor an icon is empty, not illegal.
        // Flutter's `Tab` asserts on all-null, so give it an empty label
        // rather than refusing the document.
        final label = (tab['label'] ?? tab['text']) as String?;
        final hasIcon = tab['icon'] != null;
        return Tab(
          // Canonical 'label', legacy alias 'text'.
          text: label ?? (hasIcon ? null : ''),
          // Through the shared resolver: the local switch this replaced knew
          // three names and answered `Icons.tab` for everything else, so a
          // declared icon came out as a plausible WRONG glyph rather than as
          // the missing-icon cue.
          icon: hasIcon ? Icon(resolveIconRef(tab['icon'])) : null,
          iconMargin: parseEdgeInsets(tab['iconMargin']) ??
              const EdgeInsets.only(bottom: 10),
          height: tab['height']?.toDouble(),
        );
      }
      return Tab(text: tab.toString());
    }).toList();

    // Extract properties
    final isScrollable = boolOf(properties['isScrollable'], context) ?? false;
    final padding = edgeInsetsOf(properties['padding'], context);
    final indicatorColor =
        parseColor(context.resolve(properties['indicatorColor']), context);
    final indicatorWeight = dimensionOf(properties['indicatorWeight'], context) ?? 2.0;
    final indicatorPadding =
        edgeInsetsOf(properties['indicatorPadding'], context) ?? EdgeInsets.zero;
    final indicator = _parseDecoration(properties['indicator'], context);
    final indicatorSize =
        _parseTabBarIndicatorSize(properties['indicatorSize']);
    final labelColor = parseColor(context.resolve(properties['labelColor']), context);
    final labelStyle = _parseTextStyle(properties['labelStyle'], context);
    final labelPadding = edgeInsetsOf(properties['labelPadding'], context);
    final unselectedLabelColor =
        parseColor(context.resolve(properties['unselectedLabelColor']), context);
    final unselectedLabelStyle =
        _parseTextStyle(properties['unselectedLabelStyle'], context);
    const dragStartBehavior = DragStartBehavior.start;
    final overlayColor = properties['overlayColor'] != null
        ? WidgetStateProperty.all(
            parseColor(context.resolve(properties['overlayColor']), context))
        : null;
    final mouseCursor = _parseMouseCursor(properties['mouseCursor']);
    final enableFeedback = boolOf(properties['enableFeedback'], context);
    final physics = _parseScrollPhysics(properties['physics']);

    // Canonical `selectedIndex` + `onChange`. Accept legacy
    // Flutter-style `onTap` / `click` as aliases.
    final selectedIndex = (properties['selectedIndex'] is int)
        ? properties['selectedIndex'] as int
        : intOf(properties['selectedIndex'], context) ?? 0;
    final onChange = actionOf(
        properties['onChange'] ??
            properties['onTap'] ??
            properties['click'] ??
            properties['change'],
        context);

    // Wrap TabBar with DefaultTabController to provide required TabController
    Widget tabBar = DefaultTabController(
      length: tabs.length,
      initialIndex: selectedIndex.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1),
      child: TabBar(
        tabs: tabs,
        isScrollable: isScrollable,
        padding: padding,
        indicatorColor: indicatorColor,
        indicatorWeight: indicatorWeight,
        indicatorPadding: indicatorPadding,
        indicator: indicator,
        indicatorSize: indicatorSize,
        labelColor: labelColor,
        labelStyle: labelStyle,
        labelPadding: labelPadding,
        unselectedLabelColor: unselectedLabelColor,
        unselectedLabelStyle: unselectedLabelStyle,
        dragStartBehavior: dragStartBehavior,
        overlayColor: overlayColor,
        mouseCursor: mouseCursor,
        enableFeedback: enableFeedback,
        onTap: onChange != null
            ? (index) {
                final eventContext = context.createChildContext(
                  variables: {
                    'event': {'index': index, 'type': 'change'},
                  },
                );
                context.actionHandler.execute(onChange, eventContext);
              }
            : null,
        physics: physics,
      ),
    );

    return applyCommonWrappers(tabBar, properties, context);
  }

  TabBarIndicatorSize _parseTabBarIndicatorSize(String? size) {
    switch (size) {
      case 'tab':
        return TabBarIndicatorSize.tab;
      case 'label':
        return TabBarIndicatorSize.label;
      default:
        return TabBarIndicatorSize.tab;
    }
  }

  Decoration? _parseDecoration(dynamic decoration, RenderContext context) {
    if (decoration == null) return null;

    // String binding form — resolves to a Map.
    if (decoration is String) {
      final resolved = context.resolve<dynamic>(decoration);
      if (resolved is Map) {
        decoration = Map<String, dynamic>.from(resolved);
      } else {
        return null;
      }
    }
    if (decoration is! Map<String, dynamic>) return null;

    final type = decoration['type'] as String?;
    switch (type) {
      case 'underline':
        return UnderlineTabIndicator(
          borderSide: BorderSide(
            width: decoration['width']?.toDouble() ?? 2.0,
            color:
                parseColor(context.resolve(decoration['color']), context) ??
                    context.themeManager.colorOr('primary', Colors.blue),
          ),
          insets: parseEdgeInsets(decoration['insets']) ?? EdgeInsets.zero,
        );
      default:
        return null;
    }
  }

  TextStyle? _parseTextStyle(
      Map<String, dynamic>? style, RenderContext context) {
    if (style == null) return null;

    return TextStyle(
      color: parseColor(context.resolve(style['color']), context),
      fontSize: style['fontSize']?.toDouble(),
      fontWeight: _parseFontWeight(style['fontWeight']),
    );
  }

  FontWeight? _parseFontWeight(String? value) {
    switch (value) {
      case 'bold':
        return FontWeight.bold;
      case 'normal':
        return FontWeight.normal;
      default:
        return null;
    }
  }

  MouseCursor? _parseMouseCursor(String? cursor) {
    switch (cursor) {
      case 'click':
        return SystemMouseCursors.click;
      case 'basic':
        return SystemMouseCursors.basic;
      default:
        return null;
    }
  }

  ScrollPhysics? _parseScrollPhysics(String? physics) {
    switch (physics) {
      case 'never':
        return const NeverScrollableScrollPhysics();
      case 'bouncing':
        return const BouncingScrollPhysics();
      case 'clamping':
        return const ClampingScrollPhysics();
      default:
        return null;
    }
  }

}
