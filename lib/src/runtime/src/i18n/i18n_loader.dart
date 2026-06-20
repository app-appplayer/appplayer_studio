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

  /// Load translations from MCP UI DSL format
  static Future<void> loadFromMcpFormat(Map<String, dynamic> i18nData) async {
    // MCP UI DSL format:
    // {
    //   "locales": ["en", "es", "fr"],
    //   "defaultLocale": "en",
    //   "translations": {
    //     "en": {
    //       "greeting": "Hello",
    //       "welcome": "Welcome {name}"
    //     },
    //     "es": {
    //       "greeting": "Hola",
    //       "welcome": "Bienvenido {name}"
    //     }
    //   }
    // }

    // Load all translations including default locale
    await I18nManager.instance.loadTranslations({
      'fallbackLocale': i18nData['defaultLocale'] ?? 'en',
      'translations': i18nData['translations'],
      'remoteUrl': i18nData['remoteUrl'],
    });
  }

  /// Set current locale from string
  static void setLocale(String localeString) {
    I18nManager.instance.setLocale(localeString);
  }
}
