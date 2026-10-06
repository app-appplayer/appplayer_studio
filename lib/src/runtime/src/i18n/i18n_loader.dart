import 'dart:convert';
import 'package:flutter/services.dart';
import 'i18n_manager.dart';
import '../utils/mcp_logger.dart';

/// Loader for i18n translations
class I18nLoader {
  static final _logger = MCPLogger('I18nLoader');
  /// Load translations from a JSON asset
  static Future<void> loadFromAsset(String assetPath) async {
    try {
      final jsonString = await rootBundle.loadString(assetPath);
      final Map<String, dynamic> jsonData = json.decode(jsonString);

      // Load translations using the I18nManager API
      await I18nManager.instance.loadTranslations({
        'translations': jsonData,
      });
    } catch (e) {
      _logger.error('Error loading i18n translations from $assetPath: $e');
    }
  }

  /// Load translations from a map (useful for inline translations)
  static Future<void> loadFromMap(
      Map<String, Map<String, dynamic>> translations) async {
    await I18nManager.instance.loadTranslations({
      'translations': translations,
    });
  }

  /// Load an `ApplicationDefinition.i18n` block (§12.1) into the shared
  /// [I18nManager.instance] — `defaultLocale`, `text`, `pluralization`,
  /// `numberFormat`, `dateFormat` and `textDirection`. A runtime engine loads
  /// its own document's block itself; this is for a host that renders
  /// outside one.
  static Future<void> loadFromMcpFormat(
    Map<String, dynamic> i18nData, {
    List<String> preferredLocales = const [],
  }) =>
      I18nManager.instance
          .loadDefinition(i18nData, preferredLocales: preferredLocales);

  /// Set current locale from string
  static void setLocale(String localeString) {
    I18nManager.instance.setLocale(localeString);
  }
}
