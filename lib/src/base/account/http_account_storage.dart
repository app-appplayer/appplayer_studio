/// The account storage surface over HTTP, against AppPlayer Apps.
///
/// The contract is `specs/platform/20-account-storage.md`; this file only puts
/// it on the wire. Nothing here reads meaning out of a body — bodies travel as
/// bytes, `contentType` is carried and handed back, and `version` is compared
/// and never parsed.
///
/// **A body past the inline ceiling still goes through `put`.** The contract
/// (§1.2) keeps the surface at five calls and moves the bytes by ticket: the
/// server hands back a place to upload to, and the record is only born once the
/// bytes land. That sequence lives here, not above — a caller storing a bundle
/// asks for the same thing a caller storing a theme does.
///
/// **Refusals are not flattened.** The server distinguishes three, and each one
/// needs a different move from the caller: a conflict is merged, a full account
/// is emptied or grown, and a body past the inline ceiling travels another way.
/// Collapsing them into "save failed" is what leaves a person with nothing to do.
///
/// This file names no platform library beyond `dart:convert` and the injected
/// transport, so it runs in a browser and on a device alike.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'account_storage.dart';
import 'transfer_transport.dart';

/// One HTTP round trip, injected so this file names no client library.
///
/// Returning the status alongside the body is deliberate: the refusals are
/// carried by status, and a transport that threw on non-200 would erase the
/// difference between them before this layer could read it.
typedef HttpSend = Future<HttpReply> Function(HttpRequest request);

class HttpRequest {
  const HttpRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.body,
  });

  final String method;

  /// Relative to the API base — the caller's transport owns the origin.
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? body;
}

class HttpReply {
  const HttpReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

/// Raised when the server refused for a reason this surface does not model.
///
/// Kept distinct from the three contract refusals so an unexpected failure is
/// never mistaken for one of them — a caller that retries a conflict would
/// retry forever against, say, an expired session.
class StorageUnavailable implements Exception {
  StorageUnavailable(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'StorageUnavailable($status): $message';
}

class HttpAccountStorage implements AccountStorage {
  HttpAccountStorage(
    this._send,
    this._transfer, {
    Future<void> Function(Duration) sleep = _wait,
  }) : _sleep = sleep;

  final HttpSend _send;
  final TransferTransport _transfer;

  /// How the wait between "the bytes landed" and "the record exists" is spent.
  /// Injected so tests do not pay it in real time.
  final Future<void> Function(Duration) _sleep;

  static Future<void> _wait(Duration d) => Future<void>.delayed(d);

  /// How long to wait for the record to appear after an upload completes.
  ///
  /// The version is issued when the object lands, by a handler the client
  /// cannot see — so a `put` that returns before then would be returning a
  /// version that does not exist yet. Bounded: if it never appears, that is a
  /// failure to report, not a wait to extend.
  static const _appearAttempts = 10;
  static const _appearDelay = Duration(milliseconds: 400);

  /// The server's inline ceiling, learned from `usage()` and refreshed with it.
  ///
  /// Not a constant: a constant makes the client wrong first on the day the
  /// server changes it. Zero means "not learned yet", and a write then asks
  /// before refusing rather than guessing a limit.
  int _inlineCeiling = 0;

  /// The size no route accepts — the server knows it, so it is learned from `usage()` too.
  ///
  /// It resembles `inlineCeiling` but means the opposite: passing the ceiling only **changes the route**,
  /// passing this is a **refusal**. So it is refused here, by name, before uploading — a caller that learns
  /// the limit only from the refusal learns it after uploading 600 MB.
  int _maxBody = 0;

  String _p(StorageScope scope) =>
      '/me/storage/${Uri.encodeComponent(scope.wire)}';

  @override
  Future<List<RecordInfo>> list(StorageScope scope, {String? prefix}) async {
    final r = await _ok(
      HttpRequest(
        method: 'GET',
        path: _p(scope),
        query: {if (prefix != null && prefix.isNotEmpty) 'prefix': prefix},
      ),
    );
    final entries = r['entries'];
    if (entries is! List) return const [];
    return entries.whereType<Map<String, dynamic>>().map(_infoOf).toList();
  }

  @override
  Future<StoredRecord?> get(StorageScope scope, String key) async {
    final r = await _ok(
      HttpRequest(method: 'GET', path: _p(scope), query: {'key': key}),
    );
    // Absence is not an error — a record never written is null.
    if (r.isEmpty || (r['body'] == null && r['transfer'] == null)) return null;
    final ticket = r['transfer'];
    if (ticket is Map) {
      // A large body comes by ticket. It is turned back into bytes here so the layer above has no
      // size-dependent code — lifting that branch up puts the same branch in every caller.
      final bytes = await _transfer.download('${ticket['url']}');
      return StoredRecord(
        body: bytes,
        contentType: '${r['contentType'] ?? 'application/octet-stream'}',
        version: '${r['version']}',
        updatedAt: _timeOf(r['updatedAt']),
      );
    }
    return _recordOf(r);
  }

  /// A large-body write — take a place, upload, wait until the record exists (contract §1.2).
  ///
  /// Success is not returned right after the upload. The version is issued after the object lands, so
  /// returning earlier would hand the layer above **a version that does not exist yet**.
  Future<WriteReceipt> _putByTransfer(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async {
    final reply = await _send(
      HttpRequest(
        method: 'PUT',
        path: _p(scope),
        body: {
          'key': key,
          'size': body.length,
          'contentType': contentType,
          if (ifMatch != null) 'ifMatch': ifMatch,
        },
      ),
    );
    if (reply.status != 200) {
      await _throwRefusal(reply, scope, key, needed: body.length);
    }
    final ticket = reply.body['transfer'];
    if (ticket is! Map) {
      throw StorageUnavailable(
        reply.status,
        'server did not open a transfer ticket',
      );
    }

    // Note the current version **before** uploading. Without it, treating "a version exists" as success
    // would, on an overwrite, mistake the **old version** still there at the first read for the new one.
    final before = await _versionOf(scope, key);

    await _transfer.upload('${ticket['url']}', body, contentType);

    // The storage announces arrival; this side knows it by the record changing.
    for (var i = 0; i < _appearAttempts; i++) {
      final row = await _entryOf(scope, key);
      if (row != null && row.version != before) {
        return WriteReceipt(version: row.version, updatedAt: row.updatedAt);
      }
      await _sleep(_appearDelay);
    }
    // The bytes went but no record appeared — refused for lack of room, or another device wrote meanwhile.
    // Not reported as success.
    throw StorageUnavailable(
      0,
      'upload completed but the record has not appeared',
    );
  }

  Future<RecordInfo?> _entryOf(StorageScope scope, String key) async {
    for (final row in await list(scope, prefix: key)) {
      if (row.key == key) return row;
    }
    return null;
  }

  Future<String?> _versionOf(StorageScope scope, String key) async =>
      (await _entryOf(scope, key))?.version;

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async {
    // Ask first when the ceiling is not known yet. Sending blind puts on the network what the server will
    // refuse, and leaves room to mistake that refusal for something other than size.
    if (_inlineCeiling == 0) await usage();
    if (_maxBody > 0 && body.length > _maxBody) {
      throw BodyTooLarge(
        scope: scope,
        key: key,
        size: body.length,
        ceiling: _maxBody,
      );
    }
    if (_inlineCeiling > 0 && body.length > _inlineCeiling) {
      return _putByTransfer(
        scope,
        key,
        body,
        contentType: contentType,
        ifMatch: ifMatch,
      );
    }

    final reply = await _send(
      HttpRequest(
        method: 'PUT',
        path: _p(scope),
        body: {
          'key': key,
          'body': base64Encode(body),
          'contentType': contentType,
          if (ifMatch != null) 'ifMatch': ifMatch,
        },
      ),
    );
    if (reply.status == 200) {
      return WriteReceipt(
        version: reply.body['version'] as String,
        updatedAt: _timeOf(reply.body['updatedAt']),
      );
    }
    await _throwRefusal(reply, scope, key, needed: body.length);
  }

  @override
  Future<void> delete(StorageScope scope, String key, {String? ifMatch}) async {
    final reply = await _send(
      HttpRequest(
        method: 'DELETE',
        path: _p(scope),
        query: {'key': key, if (ifMatch != null) 'ifMatch': ifMatch},
      ),
    );
    if (reply.status == 200) return;
    await _throwRefusal(reply, scope, key, needed: 0);
  }

  @override
  Future<StorageUsage> usage() async {
    final r = await _ok(const HttpRequest(method: 'GET', path: '/me/quota'));
    final ceiling = (r['inlineCeiling'] as num?)?.toInt() ?? 0;
    _inlineCeiling = ceiling;
    _maxBody = (r['maxBodyBytes'] as num?)?.toInt() ?? 0;
    return StorageUsage(
      used: (r['used'] as num?)?.toInt() ?? 0,
      limit: (r['limit'] as num?)?.toInt() ?? 0,
      byScope: {
        for (final e
            in (r['byScope'] as Map?)?.entries ??
                const <MapEntry<dynamic, dynamic>>[])
          '${e.key}': (e.value as num?)?.toInt() ?? 0,
      },
      inlineCeiling: ceiling,
      // 0 is not "unlimited" but **"the server did not say"** (contract §4). Then the refusal speaks.
      maxBodyBytes: _maxBody,
    );
  }

  /// Turns a refusal back into one of the contract's three. Any other failure **is not disguised as one of them.**
  Future<Never> _throwRefusal(
    HttpReply reply,
    StorageScope scope,
    String key, {
    required int needed,
  }) async {
    final error = reply.body['error'];
    final message = error is Map ? '${error['message']}' : 'request failed';

    if (reply.status == 409) {
      final current = reply.body['current'];
      // A large body's 409 carries no `current` (contract §1.2.1) — there is no difference to merge.
      throw VersionConflict(
        scope: scope,
        key: key,
        current: current is Map<String, dynamic> ? _recordOf(current) : null,
      );
    }
    if (reply.status == 507) {
      // Remaining room is the server's to know, so usage is read again after the refusal for the exact value.
      final u = await usage();
      throw QuotaExceeded(scope: scope, key: key, needed: needed, usage: u);
    }
    throw StorageUnavailable(reply.status, message);
  }

  Future<Map<String, dynamic>> _ok(HttpRequest request) async {
    final reply = await _send(request);
    if (reply.status == 200) return reply.body;
    final error = reply.body['error'];
    throw StorageUnavailable(
      reply.status,
      error is Map ? '${error['message']}' : 'request failed',
    );
  }

  RecordInfo _infoOf(Map<String, dynamic> m) => RecordInfo(
    key: '${m['key']}',
    size: (m['size'] as num?)?.toInt() ?? 0,
    version: '${m['version']}',
    updatedAt: _timeOf(m['updatedAt']),
  );

  StoredRecord _recordOf(Map<String, dynamic> m) => StoredRecord(
    body: Uint8List.fromList(base64Decode('${m['body']}')),
    contentType: '${m['contentType'] ?? 'application/octet-stream'}',
    version: '${m['version']}',
    updatedAt: _timeOf(m['updatedAt']),
  );

  /// Server timestamps come in more than one shape (Firestore `{_seconds}` · ISO string · epoch).
  /// **An unknown shape is not replaced with now** — that would make an old record look fresh.
  static DateTime _timeOf(Object? raw) {
    if (raw is String)
      return DateTime.tryParse(raw)?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    if (raw is num)
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
    if (raw is Map) {
      final s = raw['_seconds'] ?? raw['seconds'];
      if (s is num)
        return DateTime.fromMillisecondsSinceEpoch(
          s.toInt() * 1000,
          isUtc: true,
        );
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}
