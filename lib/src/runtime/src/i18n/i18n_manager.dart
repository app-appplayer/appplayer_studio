import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/mcp_logger.dart';

/// Manager for internationalization support according to MCP UI DSL v1.0
class I18nManager extends ChangeNotifier {
  static I18nManager? _instance;
  static I18nManager get instance => _instance ??= I18nManager._();

  I18nManager._();

  // Current locale
  String _currentLocale = 'en';
  String get currentLocale => _currentLocale;

  // Translations storage - nested structure for dot notation support
  final Map<String, Map<String, dynamic>> _translations = {};

  // Fallback locale
  String _fallbackLocale = 'en';
  String get fallbackLocale => _fallbackLocale;

  final MCPLogger _logger = MCPLogger('I18nManager');

  /// Set the current locale
  void setLocale(String locale) {
    _currentLocale = locale;
    _logger.debug('Locale changed to: $locale');
    notifyListeners();
  }

  /// Set the fallback locale
  void setFallbackLocale(String locale) {
    _fallbackLocale = locale;
    _logger.debug('Fallback locale set to: $locale');
  }

  /// Load translations from configuration
  Future<void> loadTranslations(Map<String, dynamic> i18nConfig) async {
    _fallbackLocale = i18nConfig['fallbackLocale'] ?? 'en';
    final translations = i18nConfig['translations'] as Map<String, dynamic>?;

    if (translations != null) {
      _translations.addAll(translations.map(
          (key, value) => MapEntry(key, Map<String, dynamic>.from(value))));
    }

    final remoteUrl = i18nConfig['remoteUrl'] as String?;
    if (remoteUrl != null) {
      await _loadRemoteTranslations(remoteUrl);
    }

    notifyListeners();
  }

  /// Load translations from remote URL
  Future<void> _loadRemoteTranslations(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        data.forEach((locale, translations) {
          if (translations is Map) {
            _translations[locale] = Map<String, dynamic>.from(translations);
          }
        });
        _logger.debug('Loaded remote translations from: $url');
      } else {
        _logger.error(
            'Failed to load remote translations: ${response.statusCode}');
      }
    } catch (e) {
      _logger.error('Error loading remote translations', e);
    }
  }

  /// Get a translated string with dot notation support
  String translate(String key, {Map<String, dynamic>? params}) {
    final keys = key.split('.');
    dynamic value = _translations[_currentLocale];

    for (final k in keys) {
      if (value is Map) {
        value = value[k];
      } else {
        break;
      }
    }

    if (value == null && _currentLocale != _fallbackLocale) {
      value = _getFromLocale(_fallbackLocale, keys);
    }

    if (value is String && params != null) {
      return _interpolate(value, params);
    }

    return value?.toString() ?? key;
  }

  /// Get value from locale with keys path
  dynamic _getFromLocale(String locale, List<String> keys) {
    dynamic value = _translations[locale];

    for (final key in keys) {
      if (value is Map) {
        value = value[key];
      } else {
        return null;
      }
    }

    return value;
  }

  /// Interpolate parameters into string
  String _interpolate(String value, Map<String, dynamic> params) {
    String result = value;
    params.forEach((key, val) {
      result = result.replaceAll('{{$key}}', val.toString());
      result = result.replaceAll('{$key}', val.toString());
    });
    return result;
  }

  /// Plural form support
  String plural(String key, int count, {Map<String, dynamic>? params}) {
    final pluralKey = '$key.${_getPluralForm(count)}';
    return translate(pluralKey, params: {...?params, 'count': count});
  }

  /// Get plural form based on CLDR plural rules for major locales
  String _getPluralForm(int count) {
    final lang = _currentLocale.split(RegExp(r'[-_]')).first.toLowerCase();

    switch (lang) {
      // English, German, Dutch, Italian, Spanish, Portuguese, etc.
      case 'en':
      case 'de':
      case 'nl':
      case 'it':
      case 'es':
      case 'pt':
      case 'hi':
        if (count == 0) return 'zero';
        if (count == 1) return 'one';
        return 'other';

      // French: 0 and 1 are singular
      case 'fr':
        if (count == 0) return 'zero';
        if (count == 0 || count == 1) return 'one';
        return 'other';

      // Arabic: 6 forms (zero, one, two, few, many, other)
      case 'ar':
        if (count == 0) return 'zero';
        if (count == 1) return 'one';
        if (count == 2) return 'two';
        final mod100 = count % 100;
        if (mod100 >= 3 && mod100 <= 10) return 'few';
        if (mod100 >= 11 && mod100 <= 99) return 'many';
        return 'other';

      // Russian, Ukrainian: one, few, many, other
      case 'ru':
      case 'uk':
        final mod10 = count % 10;
        final mod100 = count % 100;
        if (count == 0) return 'zero';
        if (mod10 == 1 && mod100 != 11) return 'one';
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return 'few';
        }
        return 'many';

      // Polish: one, few, many, other
      case 'pl':
        final mod10 = count % 10;
        final mod100 = count % 100;
        if (count == 0) return 'zero';
        if (count == 1) return 'one';
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return 'few';
        }
        return 'many';

      // Japanese, Korean, Chinese, Thai, Vietnamese: no plural forms
      case 'ja':
      case 'ko':
      case 'zh':
      case 'th':
      case 'vi':
        if (count == 0) return 'zero';
        return 'other';

      // Hebrew: one, two, other
      case 'he':
        if (count == 0) return 'zero';
        if (count == 1) return 'one';
        if (count == 2) return 'two';
        return 'other';

      default:
        if (count == 0) return 'zero';
        if (count == 1) return 'one';
        return 'other';
    }
  }

  /// RTL locales based on CLDR data
  static const Set<String> _rtlLocales = {
    'ar', 'he', 'fa', 'ur', 'ps', 'sd', 'yi', 'ku', 'ckb', 'dv', 'syr',
  };

  /// Determine if the current locale is RTL
  /// When rtlSetting is "auto", uses locale to detect.
  /// When "true"/"false", uses the explicit setting.
  bool isRtl({String? rtlSetting}) {
    if (rtlSetting == 'true') return true;
    if (rtlSetting == 'false') return false;
    // "auto" or null — detect from locale
    final lang = _currentLocale.split(RegExp(r'[-_]')).first.toLowerCase();
    return _rtlLocales.contains(lang);
  }

  /// Check if a locale is supported
  bool isLocaleSupported(String locale) {
    return _translations.containsKey(locale);
  }

  /// Get all supported locales
  List<String> getSupportedLocales() {
    return _translations.keys.toList();
  }

  /// Clear all translations
  void clear() {
    _translations.clear();
  }

  /// Handle i18n key format from MCP UI DSL
  /// Format: "i18n:key" or "i18n:key:arg1,arg2"
  String? resolveI18nString(String? value) {
    if (value == null || !value.startsWith('i18n:')) {
      return value;
    }

    // Remove i18n: prefix
    final content = value.substring(5);

    // Check for arguments
    final parts = content.split(':');
    final key = parts[0];

    Map<String, dynamic>? params;
    if (parts.length > 1) {
      // Parse arguments
      params = {};
      final argPairs = parts[1].split(',');
      for (final pair in argPairs) {
        final keyValue = pair.split('=');
        if (keyValue.length == 2) {
          params[keyValue[0]] = keyValue[1];
        }
      }
    }

    return translate(key, params: params);
  }

  /// Resolve a value that might be an i18n key
  dynamic resolve(dynamic value) {
    if (value is String) {
      return resolveI18nString(value) ?? value;
    }
    return value;
  }

  /// Load translations for a specific locale
  void loadLocaleTranslations(
      String locale, Map<String, dynamic> translations) {
    _translations[locale] = translations;
    _logger.debug('Loaded translations for locale: $locale');
    notifyListeners();
  }

  /// Get nested value from translations
  dynamic getNestedValue(String locale, String path) {
    final keys = path.split('.');
    return _getFromLocale(locale, keys);
  }

  /// Check if a translation key exists for the current locale
  bool hasKey(String key) {
    final keys = key.split('.');
    dynamic value = _translations[_currentLocale];

    for (final k in keys) {
      if (value is Map) {
        if (!value.containsKey(k)) return false;
        value = value[k];
      } else {
        return false;
      }
    }

    return true;
  }

  /// Return all top-level keys for the current locale
  Set<String> get translationKeys {
    final localeTranslations = _translations[_currentLocale];
    if (localeTranslations == null) return {};
    return localeTranslations.keys.toSet();
  }

  /// Format a number as currency using basic Dart formatting
  String formatCurrency(num value, {String? currency, String? locale}) {
    final effectiveLocale = locale ?? _currentLocale;
    final effectiveCurrency = currency ?? _defaultCurrencyForLocale(effectiveLocale);
    final formatted = _formatNumberWithGrouping(value.toDouble(), effectiveLocale, decimalDigits: 2);
    final symbol = _currencySymbol(effectiveCurrency);
    return '$symbol$formatted';
  }

  /// Format a date using basic Dart formatting
  String formatDate(DateTime date, {String? pattern, String? locale}) {
    if (pattern != null) {
      return _formatDateWithPattern(date, pattern);
    }
    // Default yMd format
    return '${date.month}/${date.day}/${date.year}';
  }

  /// Format a number with locale-specific grouping
  String formatNumber(num value, {String? locale}) {
    final effectiveLocale = locale ?? _currentLocale;
    if (value is int) {
      return _addThousandSeparator(value.toString(), effectiveLocale);
    }
    final parts = value.toString().split('.');
    final intPart = _addThousandSeparator(parts[0], effectiveLocale);
    final decSep = _decimalSeparator(effectiveLocale);
    return parts.length > 1 ? '$intPart$decSep${parts[1]}' : intPart;
  }

  /// Format as percentage
  String formatPercent(double value, {String? locale}) {
    final effectiveLocale = locale ?? _currentLocale;
    final percentage = (value * 100).round();
    final formatted = _addThousandSeparator(percentage.toString(), effectiveLocale);
    return '$formatted%';
  }

  // --- Private helpers for formatting ---

  String _addThousandSeparator(String integerStr, String locale) {
    final isNegative = integerStr.startsWith('-');
    final digits = isNegative ? integerStr.substring(1) : integerStr;
    final sep = _groupSeparator(locale);
    final buffer = StringBuffer();
    final len = digits.length;
    for (int i = 0; i < len; i++) {
      if (i > 0 && (len - i) % 3 == 0) {
        buffer.write(sep);
      }
      buffer.write(digits[i]);
    }
    return isNegative ? '-${buffer.toString()}' : buffer.toString();
  }

  String _formatNumberWithGrouping(double value, String locale, {int decimalDigits = 2}) {
    final fixed = value.toStringAsFixed(decimalDigits);
    final parts = fixed.split('.');
    final intPart = _addThousandSeparator(parts[0], locale);
    final decSep = _decimalSeparator(locale);
    return '$intPart$decSep${parts[1]}';
  }

  String _groupSeparator(String locale) {
    final lang = locale.split(RegExp(r'[-_]')).first.toLowerCase();
    // Languages that use period as thousand separator
    if ({'de', 'fr', 'es', 'it', 'pt', 'nl', 'ru', 'pl', 'uk'}.contains(lang)) {
      return '.';
    }
    return ',';
  }

  String _decimalSeparator(String locale) {
    final lang = locale.split(RegExp(r'[-_]')).first.toLowerCase();
    if ({'de', 'fr', 'es', 'it', 'pt', 'nl', 'ru', 'pl', 'uk'}.contains(lang)) {
      return ',';
    }
    return '.';
  }

  String _defaultCurrencyForLocale(String locale) {
    final lang = locale.split(RegExp(r'[-_]')).first.toLowerCase();
    switch (lang) {
      case 'en': return 'USD';
      case 'ko': return 'KRW';
      case 'ja': return 'JPY';
      case 'de': case 'fr': case 'es': case 'it': case 'nl': case 'pt': return 'EUR';
      case 'ru': return 'RUB';
      case 'zh': return 'CNY';
      default: return 'USD';
    }
  }

  String _currencySymbol(String currency) {
    switch (currency.toUpperCase()) {
      case 'USD': return '\$';
      case 'EUR': return '€';
      case 'GBP': return '£';
      case 'JPY': return '¥';
      case 'KRW': return '₩';
      case 'CNY': return '¥';
      case 'RUB': return '₽';
      default: return '$currency ';
    }
  }

  String _formatDateWithPattern(DateTime date, String pattern) {
    var result = pattern;
    result = result.replaceAll('yyyy', date.year.toString().padLeft(4, '0'));
    result = result.replaceAll('yy', (date.year % 100).toString().padLeft(2, '0'));
    result = result.replaceAll('MM', date.month.toString().padLeft(2, '0'));
    result = result.replaceAll('dd', date.day.toString().padLeft(2, '0'));
    result = result.replaceAll('HH', date.hour.toString().padLeft(2, '0'));
    result = result.replaceAll('mm', date.minute.toString().padLeft(2, '0'));
    result = result.replaceAll('ss', date.second.toString().padLeft(2, '0'));
    return result;
  }
}
