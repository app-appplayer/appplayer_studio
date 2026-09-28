/// A bundle's `kb` records in account storage — the host side of the kernel's
/// [KbAccountRecords].
///
/// Bundle spec 04_Tools §4.8.1 and platform spec 20 §2: a bundle's own app
/// data lives in the account's `app/<appId>` scope. Each key is its own record
/// under the account key the kernel gives (`kb/<key>`, §2.1.2), so two devices
/// editing different keys never meet, and the account's version is what a
/// write is conditioned on.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:brain_kernel/brain_kernel.dart'
    show KbAccountConflict, KbAccountRecords, KbError, KbRecord;

import 'account_storage.dart';
import 'http_account_storage.dart' show StorageUnavailable;

class AccountStorageKbRecords implements KbAccountRecords {
  AccountStorageKbRecords(this.storage);

  final AccountStorage storage;

  static const String _contentType = 'application/json';

  /// Statuses that say "not now" rather than "no": an expired sign-in being
  /// renewed, a timeout, throttling. With no status and 5xx they leave the
  /// write waiting on the device.
  static const Set<int> _notNow = {401, 403, 408, 429};

  StorageScope _scope(String appId) => StorageScope.app(appId);

  KbRecord? _decode(String key, StoredRecord? record) {
    if (record == null) return null;
    final json = jsonDecode(utf8.decode(record.body));
    final value = json is Map ? json['value'] : null;
    return KbRecord(key: key, value: value, version: record.version);
  }

  Uint8List _encode(Object? value) => Uint8List.fromList(
    utf8.encode(jsonEncode(<String, Object?>{'value': value})),
  );

  /// The account's refusals, named. A refusal is never taken for an
  /// unreachable account (platform spec 20 §1): a write queued on it would
  /// read back as saved and never reach another device.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on QuotaExceeded catch (e) {
      throw KbError(KbError.quotaExceeded, e.toString());
    } on BodyTooLarge catch (e) {
      throw KbError(KbError.valueTooLarge, e.toString());
    } on StorageUnavailable catch (e) {
      final refused =
          e.status >= 400 && e.status < 500 && !_notNow.contains(e.status);
      if (!refused) rethrow;
      final code =
          e.status == 400 && e.message.contains('key')
              ? KbError.invalidKey
              : KbError.unavailable;
      throw KbError(
        code,
        'account storage refused: ${e.message} (${e.status})',
      );
    }
  }

  @override
  Future<KbRecord?> read(String appId, String key) =>
      _guard(() async => _decode(key, await storage.get(_scope(appId), key)));

  @override
  Future<List<KbRecord>> list(String appId, String prefix) => _guard(() async {
    final out = <KbRecord>[];
    final scope = _scope(appId);
    for (final info in await storage.list(scope, prefix: prefix)) {
      final record = _decode(info.key, await storage.get(scope, info.key));
      if (record != null) out.add(record);
    }
    return out;
  });

  @override
  Future<String> write(
    String appId,
    String key,
    Object? value, {
    String? ifMatch,
  }) => _guard(() async {
    try {
      final receipt = await storage.put(
        _scope(appId),
        key,
        _encode(value),
        contentType: _contentType,
        ifMatch: ifMatch,
      );
      return receipt.version;
    } on VersionConflict catch (conflict) {
      throw KbAccountConflict(_decode(key, conflict.current));
    }
  });

  @override
  Future<bool> remove(String appId, String key, {String? ifMatch}) =>
      _guard(() async {
        final scope = _scope(appId);
        final existing = await storage.get(scope, key);
        try {
          await storage.delete(scope, key, ifMatch: ifMatch);
          return existing != null;
        } on VersionConflict catch (conflict) {
          throw KbAccountConflict(_decode(key, conflict.current));
        }
      });
}
