import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show ConformanceLevels;

import '../runtime/widget_registry.dart';

/// Conformance level definitions for MCP UI DSL v1.0
enum ConformanceLevel {
  /// Core conformance - Basic widget set
  core,

  /// Standard conformance - Extended widget set including navigation and forms
  standard,

  /// Advanced conformance - Full widget set including charts, maps, etc.
  advanced,
}

/// Checker for determining conformance level support.
///
/// Uses the canonical widget lists from [ConformanceLevels] in the core
/// package as the single source of truth for conformance requirements.
class ConformanceChecker {
  final WidgetRegistry widgetRegistry;

  ConformanceChecker(this.widgetRegistry);

  /// Core widgets required for Core conformance (from core package)
  static List<String> get coreWidgets => ConformanceLevels.coreWidgets;

  /// All widgets required for Standard conformance (core + standard additions)
  static List<String> get standardWidgets => ConformanceLevels.standardWidgets;

  /// All widgets required for Advanced conformance (standard + advanced additions)
  static List<String> get advancedWidgets => ConformanceLevels.advancedWidgets;

  /// Check if the runtime supports a specific conformance level
  bool supportsLevel(ConformanceLevel level) {
    switch (level) {
      case ConformanceLevel.core:
        return _hasAllWidgets(coreWidgets);
      case ConformanceLevel.standard:
        return _hasAllWidgets(standardWidgets);
      case ConformanceLevel.advanced:
        return _hasAllWidgets(advancedWidgets);
    }
  }

  /// Get the highest conformance level supported
  ConformanceLevel getConformanceLevel() {
    if (supportsLevel(ConformanceLevel.advanced)) {
      return ConformanceLevel.advanced;
    } else if (supportsLevel(ConformanceLevel.standard)) {
      return ConformanceLevel.standard;
    } else if (supportsLevel(ConformanceLevel.core)) {
      return ConformanceLevel.core;
    }
    // If not even core is supported, return core anyway
    return ConformanceLevel.core;
  }

  /// Get missing widgets for a specific conformance level
  List<String> getMissingWidgets(ConformanceLevel level) {
    final List<String> widgetsToCheck;

    switch (level) {
      case ConformanceLevel.core:
        widgetsToCheck = coreWidgets;
      case ConformanceLevel.standard:
        widgetsToCheck = standardWidgets;
      case ConformanceLevel.advanced:
        widgetsToCheck = advancedWidgets;
    }

    final missing = <String>[];
    for (final widget in widgetsToCheck) {
      if (!widgetRegistry.has(widget)) {
        missing.add(widget);
      }
    }
    return missing;
  }

  /// Get a report of conformance support
  Map<String, dynamic> getConformanceReport() {
    final coreSupport = _getWidgetSupport(coreWidgets);
    // Standard-only additions (exclude core widgets already counted)
    final standardOnlyWidgets = standardWidgets
        .where((w) => !coreWidgets.contains(w))
        .toList();
    final standardSupport = _getWidgetSupport(standardOnlyWidgets);
    // Advanced-only additions (exclude standard widgets already counted)
    final advancedOnlyWidgets = advancedWidgets
        .where((w) => !standardWidgets.contains(w))
        .toList();
    final advancedSupport = _getWidgetSupport(advancedOnlyWidgets);

    return {
      'conformanceLevel': getConformanceLevel().toString().split('.').last,
      'core': {
        'supported': coreSupport['supported'],
        'missing': coreSupport['missing'],
        'percentage': coreSupport['percentage'],
      },
      'standard': {
        'supported': standardSupport['supported'],
        'missing': standardSupport['missing'],
        'percentage': standardSupport['percentage'],
      },
      'advanced': {
        'supported': advancedSupport['supported'],
        'missing': advancedSupport['missing'],
        'percentage': advancedSupport['percentage'],
      },
    };
  }

  /// Check if all widgets in a list are available
  bool _hasAllWidgets(List<String> widgets) {
    for (final widget in widgets) {
      if (!widgetRegistry.has(widget)) {
        return false;
      }
    }
    return true;
  }

  /// Get support information for a list of widgets
  Map<String, dynamic> _getWidgetSupport(List<String> widgets) {
    final supported = <String>[];
    final missing = <String>[];

    for (final widget in widgets) {
      if (widgetRegistry.has(widget)) {
        supported.add(widget);
      } else {
        missing.add(widget);
      }
    }

    final percentage = widgets.isEmpty
        ? 100.0
        : (supported.length / widgets.length * 100).roundToDouble();

    return {
      'supported': supported,
      'missing': missing,
      'percentage': percentage,
    };
  }
}
