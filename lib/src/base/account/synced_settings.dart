/// The person's taste — the settings that move between this person's devices
/// and products.
///
/// It lives in `shell/common` (platform spec 20 §2.1.1): theme and language
/// belong to the person, so AppPlayer and Studio read and write the same
/// document. Studio has a theme and no display language of its own, but it
/// still carries every field it reads back — a push that dropped the language
/// another product set would erase that product's choice.
///
/// **A merge keeps a time per field.** Treating the whole document as "the
/// later one wins" erases one device's change when another changed a
/// different field. Keeping when each value was set next to the value keeps
/// both.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'account_storage.dart';
import 'synced_document.dart';

/// One value and **when it was set**.
class Stamped<T> {
  const Stamped(this.value, this.at);

  final T value;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'v': value,
    'at': at.toUtc().toIso8601String(),
  };

  static Stamped<T>? fromJson<T>(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null || raw['v'] is! T) return null;
    return Stamped<T>(raw['v'] as T, at);
  }
}

/// The person's taste. Crosses products.
class SyncedSettings {
  const SyncedSettings({this.theme, this.locale, this.logLevel});

  /// `system` · `light` · `dark` — Flutter's `ThemeMode` names, the spelling
  /// every product writes.
  final Stamped<String>? theme;

  /// A language code. Written by products that have a display language.
  final Stamped<String>? locale;

  /// A log level. Written by products that expose one.
  final Stamped<String>? logLevel;

  Map<String, Object?> toJson() => {
    if (theme != null) 'theme': theme!.toJson(),
    if (locale != null) 'locale': locale!.toJson(),
    if (logLevel != null) 'logLevel': logLevel!.toJson(),
  };

  static SyncedSettings fromJson(Map<String, Object?> json) => SyncedSettings(
    theme: Stamped.fromJson<String>(json['theme']),
    locale: Stamped.fromJson<String>(json['locale']),
    logLevel: Stamped.fromJson<String>(json['logLevel']),
  );

  SyncedSettings withTheme(String v, DateTime at) =>
      SyncedSettings(theme: Stamped(v, at), locale: locale, logLevel: logLevel);
}

/// Per field, the one set later stays. **One device never erases another
/// device's other field.**
Stamped<T>? _later<T>(Stamped<T>? a, Stamped<T>? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.at.isAfter(b.at) ? a : b;
}

SyncedSettings? mergeSettings({
  required SyncedSettings? base,
  required SyncedSettings mine,
  required SyncedSettings theirs,
}) => SyncedSettings(
  theme: _later(mine.theme, theirs.theme),
  locale: _later(mine.locale, theirs.locale),
  logLevel: _later(mine.logLevel, theirs.logLevel),
);

final DocumentCodec<SyncedSettings> settingsCodec =
    DocumentCodec<SyncedSettings>(
      encode: (v) => Uint8List.fromList(utf8.encode(jsonEncode(v.toJson()))),
      decode:
          (r) => SyncedSettings.fromJson(
            jsonDecode(utf8.decode(r.body)) as Map<String, Object?>,
          ),
      contentType: 'application/json',
    );

/// The taste document — `shell/common`, key `settings`. Same person, same
/// value, whichever product.
SyncedDocument<SyncedSettings> settingsDocument(AccountStorage storage) =>
    SyncedDocument<SyncedSettings>(
      storage: storage,
      scope: StorageScope.common,
      key: 'settings',
      codec: settingsCodec,
      merge: mergeSettings,
    );
