import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../utils/mcp_logger.dart';

/// Manager for internationalization support according to MCP UI DSL v1.0
class I18nManager extends ChangeNotifier {
  static I18nManager? _instance;
  static I18nManager get instance => _instance ??= I18nManager._();

  I18nManager._();

  /// A manager of its own, not the process-wide [instance].
  ///
  /// Each runtime engine holds one, so two documents open at once — two tabs
  /// of a player — never read each other's text or switch each other's
  /// locale.
  I18nManager.scoped();


  // Current locale
  String _currentLocale = 'en';
  String get currentLocale => _currentLocale;

  // Translations storage - nested structure for dot notation support
  final Map<String, Map<String, dynamic>> _translations = {};

  // Fallback locale
  String _fallbackLocale = 'en';
  String get fallbackLocale => _fallbackLocale;

  final MCPLogger _logger = MCPLogger('I18nManager');

  // The rest of an `ApplicationDefinition.i18n` block (§12.1), keyed by
  // locale and then by key.
  final Map<String, Map<String, dynamic>> _plurals = {};
  final Map<String, Map<String, dynamic>> _numberFormats = {};
  final Map<String, Map<String, dynamic>> _dateFormats = {};
  final Map<String, String> _directions = {};
  final List<String> _declaredLocales = [];

  // `locale|key` pairs already reported missing — §12.7 asks for one warning
  // per key per locale, not one per rebuild.
  final Set<String> _reportedMissing = {};

  bool _hasDefinition = false;

  /// Whether a document's `i18n` block has been loaded. A runtime that never
  /// received one leaves layout direction to its host.
  bool get hasDefinition => _hasDefinition;

  /// Loads an `ApplicationDefinition.i18n` block (§12.1) and picks the first
  /// active locale (§12.6): the first of [preferredLocales] — the host's
  /// languages, in order — that the document carries entries for, otherwise
  /// `defaultLocale`.
  Future<void> loadDefinition(
    Map<String, dynamic> i18n, {
    List<String> preferredLocales = const [],
  }) async {
    _translations.clear();
    _plurals.clear();
    _numberFormats.clear();
    _dateFormats.clear();
    _directions.clear();
    _declaredLocales.clear();
    _reportedMissing.clear();

    final defaultLocale = i18n['defaultLocale'];
    _fallbackLocale =
        defaultLocale is String ? _normalise(defaultLocale) : 'en';
    _copyLocaleMap(i18n['text'], _translations);
    _copyLocaleMap(i18n['pluralization'], _plurals);
    _copyLocaleMap(i18n['numberFormat'], _numberFormats);
    _copyLocaleMap(i18n['dateFormat'], _dateFormats);
    final directions = i18n['textDirection'];
    if (directions is Map) {
      directions.forEach((locale, direction) {
        if (direction is String) {
          _directions[_normalise('$locale')] = direction;
        }
      });
    }
    final locales = i18n['locales'];
    if (locales is List) {
      _declaredLocales.addAll(locales.whereType<String>().map(_normalise));
    }

    String? chosen;
    for (final preferred in preferredLocales) {
      chosen = matchLocale(preferred);
      if (chosen != null) break;
    }
    _currentLocale = chosen ?? _fallbackLocale;
    _hasDefinition = true;

    // Date patterns need the locale's symbols before the first format call.
    await initializeDateFormatting();
    notifyListeners();
  }

  void _copyLocaleMap(Object? source, Map<String, Map<String, dynamic>> into) {
    if (source is! Map) return;
    source.forEach((locale, entries) {
      if (entries is Map) {
        into[_normalise('$locale')] = Map<String, dynamic>.from(entries);
      }
    });
  }

  static String _normalise(String tag) => tag.replaceAll('_', '-');

  Iterable<String> get _knownLocales => {
        ..._declaredLocales,
        ..._translations.keys,
        ..._plurals.keys,
        ..._numberFormats.keys,
        ..._dateFormats.keys,
        _fallbackLocale,
      };

  /// The document's spelling of the locale closest to [requested]: the same
  /// tag (BCP 47 tags compare case-insensitively), else the first locale of
  /// the same language — a device set to `ko` reads a document's `ko-KR`.
  /// Null when the document carries nothing for that language.
  String? matchLocale(String requested) {
    final wanted = _normalise(requested).toLowerCase();
    final known = _knownLocales.toList();
    for (final tag in known) {
      if (tag.toLowerCase() == wanted) return tag;
    }
    final language = wanted.split('-').first;
    if (_fallbackLocale.toLowerCase().split('-').first == language) {
      return _fallbackLocale;
    }
    for (final tag in known) {
      if (tag.toLowerCase().split('-').first == language) return tag;
    }
    return null;
  }

  /// Layout direction for the active locale (§12.8.1): the document's
  /// `textDirection` entry, else the script's built-in direction.
  TextDirection get textDirection {
    final declared = _directions[_currentLocale];
    if (declared == 'rtl') return TextDirection.rtl;
    if (declared == 'ltr') return TextDirection.ltr;
    return isRtl() ? TextDirection.rtl : TextDirection.ltr;
  }

  /// Resolves a `{{i18n.*}}` binding (§12.2).
  ///
  /// [locale] is the explicit-locale form (`{{i18n.greeting:en-US}}`).
  /// [named] / [positional] are the argument forms; a key with arguments
  /// resolves against `pluralization`, then `numberFormat`, then
  /// `dateFormat`, then `text` (§12.2.2).
  String resolveBinding(
    String key, {
    String? locale,
    Map<String, dynamic>? named,
    List<dynamic> positional = const [],
  }) {
    final active =
        locale == null ? _currentLocale : (matchLocale(locale) ?? locale);
    if (named != null || positional.isNotEmpty) {
      if (_entry(_plurals, active, key) != null) {
        return _pluralize(key, named ?? const {}, active);
      }
      final number = _entry(_numberFormats, active, key);
      if (number != null) {
        return _formatNumberEntry(
            key,
            number,
            positional.isEmpty ? named?.values.first : positional.first,
            active);
      }
      final date = _entry(_dateFormats, active, key);
      if (date != null) {
        return _formatDateEntry(
            key,
            date,
            positional.isEmpty ? named?.values.first : positional.first,
            active);
      }
    }
    return translate(key, params: named, locale: active);
  }

  /// The entry for [key] under [locale], else under `defaultLocale` (§12.7).
  dynamic _entry(
      Map<String, Map<String, dynamic>> table, String locale, String key) {
    return table[locale]?[key] ?? table[_fallbackLocale]?[key];
  }

  /// §12.7 step 4: the key with a warning marker, and one warning per key per
  /// locale.
  String _missing(String key, String locale) {
    if (_reportedMissing.add('$locale|$key')) {
      _logger.warning('i18n key "$key" has no entry for $locale '
          'or the default locale $_fallbackLocale');
    }
    return '!!$key';
  }

  String _pluralize(String key, Map<String, dynamic> args, String locale) {
    final raw = args['count'];
    final count = raw is num ? raw : num.tryParse('$raw') ?? 0;
    String? template(String tag) {
      final forms = _plurals[tag]?[key];
      if (forms is! Map) return null;
      // An explicit zero form is honoured in every locale — the spec's own
      // en-US example writes one, though CLDR gives English no zero category.
      if (count == 0 && forms['zero'] is String) return forms['zero'] as String;
      final form = forms[cldrPluralCategory(tag, count)] ?? forms['other'];
      return form is String ? form : null;
    }

    final chosen = template(locale) ??
        (locale == _fallbackLocale ? null : template(_fallbackLocale));
    if (chosen == null) return _missing(key, locale);
    return _interpolate(
        chosen,
        args.map((name, value) =>
            MapEntry(name, value is num ? _decimal(value, locale) : value)));
  }

  String _decimal(num value, String locale) =>
      NumberFormat.decimalPattern(_intlLocale(locale)).format(value);

  String _formatNumberEntry(
      String key, dynamic descriptor, dynamic value, String locale) {
    final number = value is num ? value : num.tryParse('$value');
    if (number == null || descriptor is! Map) return _missing(key, locale);
    final intlLocale = _intlLocale(locale);
    final style = descriptor['style'] ?? 'decimal';
    final NumberFormat format;
    switch (style) {
      case 'currency':
        format = NumberFormat.simpleCurrency(
            locale: intlLocale, name: descriptor['currency'] as String?);
      case 'percent':
        format = NumberFormat.percentPattern(intlLocale);
      default:
        format = NumberFormat.decimalPattern(intlLocale);
    }
    final minimum = descriptor['minimumFractionDigits'];
    final maximum = descriptor['maximumFractionDigits'];
    if (minimum is num) format.minimumFractionDigits = minimum.toInt();
    if (maximum is num) format.maximumFractionDigits = maximum.toInt();
    if (minimum is num &&
        maximum is! num &&
        format.maximumFractionDigits < minimum.toInt()) {
      format.maximumFractionDigits = minimum.toInt();
    }
    if (descriptor['useGrouping'] == false) format.turnOffGrouping();
    return format.format(number);
  }

  String _formatDateEntry(
      String key, dynamic descriptor, dynamic value, String locale) {
    final DateTime? date = value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : (value is String ? DateTime.tryParse(value) : null);
    if (date == null) return _missing(key, locale);
    final intlLocale = _intlLocale(locale);
    if (descriptor is String) {
      return DateFormat(descriptor, intlLocale).format(date);
    }
    if (descriptor is! Map) return _missing(key, locale);
    return _dateFormatFor(descriptor, intlLocale).format(date);
  }

  /// An ECMA-402 `DateTimeFormat` option set as a locale pattern: the
  /// locale's own pattern for the fields asked for, with `2-digit` fields
  /// widened.
  static DateFormat _dateFormatFor(Map descriptor, String locale) {
    final skeleton = StringBuffer();
    final year = descriptor['year'];
    final month = descriptor['month'];
    final day = descriptor['day'];
    final weekday = descriptor['weekday'];
    final hour = descriptor['hour'];
    final minute = descriptor['minute'];
    final second = descriptor['second'];
    final hour12 = descriptor['hour12'];
    if (year != null) skeleton.write('y');
    if (month != null) {
      skeleton.write(switch (month) {
        'long' => 'MMMM',
        'short' => 'MMM',
        'narrow' => 'MMMMM',
        _ => 'M',
      });
    }
    if (weekday != null) {
      skeleton.write(weekday == 'long' ? 'EEEE' : 'E');
    }
    if (day != null) skeleton.write('d');
    if (hour != null) {
      skeleton.write(hour12 == true ? 'h' : (hour12 == false ? 'H' : 'j'));
    }
    if (minute != null) skeleton.write('m');
    if (second != null) skeleton.write('s');

    final format = DateFormat(skeleton.toString(), locale);
    var pattern = format.pattern ?? skeleton.toString();
    String widen(String pattern, String letter) => pattern.replaceAllMapped(
        RegExp('(?<![$letter])$letter(?![$letter])'), (_) => '$letter$letter');
    if (month == '2-digit') pattern = widen(pattern, 'M');
    if (day == '2-digit') pattern = widen(pattern, 'd');
    if (hour == '2-digit') {
      pattern = widen(widen(pattern, 'h'), 'H');
    }
    if (minute == '2-digit') pattern = widen(pattern, 'm');
    if (second == '2-digit') pattern = widen(pattern, 's');
    if (year == '2-digit') {
      pattern = pattern.replaceAll(RegExp('y+'), 'yy');
    }
    return DateFormat(pattern, locale);
  }

  /// [tag] in the form intl looks locale data up by, falling back to the
  /// language and then to English rather than throwing on an unknown tag.
  static String _intlLocale(String tag) =>
      Intl.verifiedLocale(
          _normalise(tag).replaceAll('-', '_'), NumberFormat.localeExists,
          onFailure: (_) => 'en') ??
      'en';

  /// The CLDR plural category of [count] in [locale] (§12.3.1), for the
  /// languages whose rules differ from English.
  static String cldrPluralCategory(String locale, num count) {
    final language = _normalise(locale).toLowerCase().split('-').first;
    final i = count.abs().truncate();
    final hasFraction = count != count.truncate();
    final mod10 = i % 10;
    final mod100 = i % 100;
    switch (language) {
      case 'ja':
      case 'ko':
      case 'zh':
      case 'th':
      case 'vi':
      case 'id':
      case 'ms':
      case 'lo':
      case 'my':
      case 'km':
        return 'other';
      case 'fr':
      case 'pt':
        return !hasFraction && (i == 0 || i == 1) ? 'one' : 'other';
      case 'ru':
      case 'uk':
      case 'be':
        if (hasFraction) return 'other';
        if (mod10 == 1 && mod100 != 11) return 'one';
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return 'few';
        }
        return 'many';
      case 'pl':
        if (hasFraction) return 'other';
        if (i == 1) return 'one';
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
          return 'few';
        }
        return 'many';
      case 'cs':
      case 'sk':
        if (hasFraction) return 'many';
        if (i == 1) return 'one';
        if (i >= 2 && i <= 4) return 'few';
        return 'other';
      case 'ar':
        if (hasFraction) return 'other';
        if (i == 0) return 'zero';
        if (i == 1) return 'one';
        if (i == 2) return 'two';
        if (mod100 >= 3 && mod100 <= 10) return 'few';
        if (mod100 >= 11 && mod100 <= 99) return 'many';
        return 'other';
      case 'he':
        if (hasFraction) return 'other';
        if (i == 1) return 'one';
        if (i == 2) return 'two';
        return 'other';
      default:
        return !hasFraction && i == 1 ? 'one' : 'other';
    }
  }

  /// Set the current locale — the document's spelling of it when the
  /// document carries that locale or its language (§12.6).
  void setLocale(String locale) {
    _currentLocale = matchLocale(locale) ?? locale;
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

  /// The client remote translations are fetched with.
  ///
  /// A [http.Client] rather than the top-level `http.get`, so a host — or a
  /// test — can supply its own. Without a seam here this path cannot be
  /// exercised at all: the only way to reach it was a real network call, and
  /// "we cannot test it" is a statement about the design, not about the code.
  static http.Client httpClient = http.Client();

  /// Load translations from remote URL
  Future<void> _loadRemoteTranslations(String url) async {
    try {
      final response = await httpClient.get(Uri.parse(url));
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

  /// The `text` entry for [key] (dot notation reaches nested maps), with
  /// [params] interpolated.
  ///
  /// Resolution follows §12.7: [locale] (the active locale when omitted),
  /// then `defaultLocale`, then the key behind a `!!` marker — a missing
  /// translation stays visible on screen instead of passing for a label.
  String translate(String key, {Map<String, dynamic>? params, String? locale}) {
    final keys = key.split('.');
    final active =
        locale == null ? _currentLocale : (matchLocale(locale) ?? locale);
    var value = _getFromLocale(active, keys);
    if (value == null && active != _fallbackLocale) {
      value = _getFromLocale(_fallbackLocale, keys);
    }
    if (value == null) return _missing(key, active);
    if (value is String && params != null) {
      return _interpolate(value, params);
    }
    return value.toString();
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
    final all = {...?params, 'count': count};
    // A key holding plain text has no forms to choose from; it is the text.
    final entry = _getFromLocale(_currentLocale, key.split('.')) ??
        _getFromLocale(_fallbackLocale, key.split('.'));
    if (entry is String) return _interpolate(entry, all);
    // A missing category falls back to `other` (§12.3.1).
    final form = _getPluralForm(count);
    if (entry is Map && entry[form] == null && entry['other'] != null) {
      return translate('$key.other', params: all);
    }
    return translate('$key.$form', params: all);
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
    _plurals.clear();
    _numberFormats.clear();
    _dateFormats.clear();
    _directions.clear();
    _declaredLocales.clear();
    _reportedMissing.clear();
    _hasDefinition = false;
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
