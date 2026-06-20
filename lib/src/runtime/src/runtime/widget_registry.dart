import 'package:flutter/foundation.dart';
import '../widgets/widget_factory.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart';
import '../utils/mcp_logger.dart';

/// Registry for widget factories
class WidgetRegistry {
  final Map<String, WidgetFactory> _factories = {};
  final Map<String, List<String>> _categorizedTypes = {};
  final MCPLogger _logger = MCPLogger('WidgetRegistry');

  /// Register a widget factory
  void register(String type, WidgetFactory factory) {
    // Store with exact case for primary registration
    _factories[type] = factory;

    // Add to categorized types
    final category = WidgetTypes.getCategoryForType(type);
    if (category != null) {
      _categorizedTypes[category] ??= [];
      if (!_categorizedTypes[category]!.contains(type)) {
        _categorizedTypes[category]!.add(type);
      }
    }
  }

  /// Get a widget factory by type
  WidgetFactory? get(String type) {
    // Look up with exact case for case-sensitive matching (MCP UI DSL v1.0)
    return _factories[type];
  }

  /// Check if a widget type is registered
  bool has(String type) {
    // Check with exact case for case-sensitive matching (MCP UI DSL v1.0)
    return _factories.containsKey(type);
  }

  /// Check if a factory exists for the given type (design doc compatibility alias)
  bool hasFactory(String type) => has(type);

  /// Get all registered widget types
  List<String> get registeredTypes {
    return _factories.keys.toList()..sort();
  }

  /// Get registered types by category
  List<String> getTypesByCategory(String category) {
    return _categorizedTypes[category] ?? [];
  }

  /// Get all categories
  List<String> get categories {
    return _categorizedTypes.keys.toList()..sort();
  }

  /// Unregister a widget factory
  void unregister(String type) {
    _factories.remove(type);

    // Remove from categorized types
    for (final list in _categorizedTypes.values) {
      list.remove(type);
    }
  }

  /// Clear all registrations
  void clear() {
    _factories.clear();
    _categorizedTypes.clear();
  }

  /// Get registration status report
  Map<String, dynamic> getRegistrationStatus() {
    final allExpectedTypes = WidgetTypes.allTypes;
    final registeredTypes = this.registeredTypes;
    final missingTypes = allExpectedTypes
        .where((type) => !registeredTypes.contains(type))
        .toList();

    final statusByCategory = <String, Map<String, dynamic>>{};
    for (final category in WidgetTypes.categories.keys) {
      final expected = WidgetTypes.getTypesByCategory(category);
      final registered = getTypesByCategory(category);
      final missing =
          expected.where((type) => !registered.contains(type)).toList();

      statusByCategory[category] = {
        'expected': expected.length,
        'registered': registered.length,
        'missing': missing,
        'percentage': expected.isEmpty
            ? 100
            : (registered.length / expected.length * 100).round(),
      };
    }

    return {
      'totalExpected': allExpectedTypes.length,
      'totalRegistered': registeredTypes.length,
      'totalMissing': missingTypes.length,
      'percentage': allExpectedTypes.isEmpty
          ? 100
          : (registeredTypes.length / allExpectedTypes.length * 100).round(),
      'missingTypes': missingTypes,
      'byCategory': statusByCategory,
    };
  }

  /// Debug print registration status
  void printRegistrationStatus() {
    final status = getRegistrationStatus();
    if (kDebugMode) {
      _logger.info('=== Widget Registration Status ===');
      _logger.info(
          'Total: ${status['totalRegistered']}/${status['totalExpected']} (${status['percentage']}%)');
      _logger.info('');
    }

    final byCategory =
        status['byCategory'] as Map<String, Map<String, dynamic>>;
    for (final entry in byCategory.entries) {
      final category = entry.key;
      final data = entry.value;
      if (kDebugMode) {
        _logger.info(
            '$category: ${data['registered']}/${data['expected']} (${data['percentage']}%)');

        final missing = data['missing'] as List;
        if (missing.isNotEmpty) {
          _logger.info('  Missing: ${missing.join(', ')}');
        }
      }
    }

    if (status['totalMissing'] > 0) {
      if (kDebugMode) {
        _logger.info(
            '\nAll missing types: ${(status['missingTypes'] as List).join(', ')}');
      }
    }
  }
}
