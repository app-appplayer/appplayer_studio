/// The HTTP implementation against the same axes the fake is held to.
///
/// The point of the port was that swapping the implementation changes nothing
/// above it — so this file asks the same questions of the wire that
/// `account_storage_test.dart` asks of the fake, plus the ones only a wire has:
/// what each refusal status means, and that an unmodelled failure is not
/// disguised as one of the three the contract defines.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/http_account_storage.dart';
import 'package:appplayer_studio/src/base/account/transfer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for AppPlayer Apps that answers in the shapes the server sends.
class FakeApps {
  FakeApps({this.limit = 1000, this.ceiling = 64, this.maxBody = 1 << 20});

  final int limit;
  final int ceiling;
  final int maxBody;

  /// Open reservations. An upload has to arrive before it becomes a record — the server's order.
  final Map<String, Map<String, dynamic>> tickets = {};
  final Map<String, Map<String, dynamic>> records = {};
  final List<HttpRequest> seen = [];
  int used = 0;
  int _version = 0;

  Future<HttpReply> send(HttpRequest r) async {
    seen.add(r);
    if (r.path == '/me/quota') {
      return HttpReply(200, {
        'used': used,
        'limit': limit,
        'remaining': limit - used,
        'byScope': {'shell': used},
        'inlineCeiling': ceiling,
        'maxBodyBytes': maxBody,
      });
    }
    final scope = Uri.decodeComponent(r.path.substring('/me/storage/'.length));
    if (r.method == 'GET') {
      final key = r.query['key'];
      if (key == null) {
        final prefix = r.query['prefix'] ?? '';
        return HttpReply(200, {
          'entries': records.entries
              .where((e) => e.value['scope'] == scope && '${e.value['key']}'.startsWith(prefix))
              .map((e) => {
                    'key': e.value['key'],
                    'size': e.value['size'],
                    'version': e.value['version'],
                    'updatedAt': e.value['updatedAt'],
                  })
              .toList(),
        });
      }
      final rec = records['$scope|$key'];
      if (rec == null) return const HttpReply(200, {});
      if (rec['body'] == null) {
        return HttpReply(200, {
          'transfer': {'url': 'https://signed/read/${rec['objectId']}', 'method': 'GET', 'expiresAt': 'T'},
          'contentType': rec['contentType'],
          'size': rec['size'],
          'version': rec['version'],
          'updatedAt': rec['updatedAt'],
        });
      }
      return HttpReply(200, rec);
    }
    if (r.method == 'PUT' && r.body!['body'] == null && r.body!['size'] != null) {
      // Size only, no body — opens a transfer ticket. No version is issued here.
      final key = '${r.body!['key']}';
      final size = r.body!['size'] as int;
      if (size > maxBody) {
        return const HttpReply(400, {'error': {'code': 'validation', 'message': 'size too large'}});
      }
      final cur = records['$scope|$key'];
      final ifMatch = r.body!['ifMatch'];
      if (ifMatch != null && (cur?['version']) != ifMatch) {
        return HttpReply(409, {
          'error': {'code': 'conflict', 'message': 'version mismatch'},
          if (cur != null) 'version': cur['version'],
        });
      }
      if (used + size - ((cur?['size'] as int?) ?? 0) > limit) {
        return const HttpReply(507, {'error': {'code': 'quota_exceeded', 'message': 'no room'}});
      }
      final id = 'up${tickets.length + 1}';
      tickets[id] = {'scope': scope, 'key': key, 'size': size, 'contentType': r.body!['contentType']};
      return HttpReply(200, {
        'transfer': {'url': 'https://signed/$id', 'method': 'PUT', 'expiresAt': '2026-08-01T01:00:00.000Z'},
        'uploadId': id,
      });
    }
    if (r.method == 'PUT') {
      final key = '${r.body!['key']}';
      final id = '$scope|$key';
      final cur = records[id];
      final ifMatch = r.body!['ifMatch'];
      if (ifMatch != null && (cur?['version']) != ifMatch) {
        return HttpReply(409, {
          'error': {'code': 'conflict', 'message': 'version mismatch'},
          if (cur != null) 'current': cur,
        });
      }
      final size = base64Decode('${r.body!['body']}').length;
      final delta = size - ((cur?['size'] as int?) ?? 0);
      if (used + delta > limit) {
        return HttpReply(507, {
          'error': {'code': 'quota_exceeded', 'message': 'not enough space to save $scope'}
        });
      }
      used += delta;
      final v = 'v${++_version}';
      records[id] = {
        'scope': scope,
        'key': key,
        'body': r.body!['body'],
        'contentType': r.body!['contentType'],
        'size': size,
        'version': v,
        'updatedAt': '2026-08-01T00:00:00.000Z',
      };
      return HttpReply(200, {'version': v, 'updatedAt': '2026-08-01T00:00:00.000Z'});
    }
    if (r.method == 'DELETE') {
      final id = '$scope|${r.query['key']}';
      final cur = records[id];
      final ifMatch = r.query['ifMatch'];
      if (cur != null && ifMatch != null && cur['version'] != ifMatch) {
        return HttpReply(409, {'error': {'code': 'conflict', 'message': 'version mismatch'}, 'current': cur});
      }
      if (cur != null) used -= cur['size'] as int;
      records.remove(id);
      return const HttpReply(200, {'ok': true});
    }
    return const HttpReply(400, {'error': {'code': 'validation', 'message': 'bad request'}});
  }
}

/// A fake transfer connecting arrived bytes to the server's completion handling (the finalize trigger).
///
/// Not completing **automatically** matters — with `autoFinalize` off, "the bytes went but no record
/// appeared" is reproduced as is, and that is exactly where a client must not report success.
class FakeTransfer implements TransferTransport {
  FakeTransfer(this.apps, {this.autoFinalize = true});

  final FakeApps apps;
  final bool autoFinalize;
  final List<({String url, int size, String contentType})> uploads = [];
  final Map<String, Uint8List> objects = {};
  int _version = 1000;

  @override
  Future<void> upload(String url, Uint8List body, String contentType) async {
    uploads.add((url: url, size: body.length, contentType: contentType));
    final id = url.split('/').last;
    objects[id] = body;
    if (autoFinalize) finalize(id);
  }

  /// The server's completion handling — builds the record from the **size actually uploaded**, issuing the version then.
  void finalize(String uploadId) {
    final t = apps.tickets.remove(uploadId);
    if (t == null) return;
    final size = objects[uploadId]!.length;
    final id = '${t['scope']}|${t['key']}';
    apps.used += size - ((apps.records[id]?['size'] as int?) ?? 0);
    apps.records[id] = {
      'scope': t['scope'],
      'key': t['key'],
      'objectId': uploadId,
      'contentType': t['contentType'],
      'size': size,
      'version': 'v${++_version}',
      'updatedAt': '2026-08-01T00:00:00.000Z',
    };
  }

  @override
  Future<Uint8List> download(String url) async {
    final id = url.split('/').last;
    final o = objects[id];
    if (o == null) throw TransferFailed(url, 404, 'no such object');
    return o;
  }
}

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late FakeApps apps;
  late FakeTransfer transfer;
  late HttpAccountStorage storage;

  setUp(() {
    apps = FakeApps();
    transfer = FakeTransfer(apps);
    storage = HttpAccountStorage(apps.send, transfer, sleep: (_) async {});
  });

  group('a record round-trips', () {
    test('what was written comes back, body and label intact', () async {
      final receipt = await storage.put(StorageScope.shell, 'layout', bytes('{"a":1}'),
          contentType: 'application/json');
      final got = await storage.get(StorageScope.shell, 'layout');
      expect(utf8.decode(got!.body), '{"a":1}');
      expect(got.contentType, 'application/json');
      expect(got.version, receipt.version);
    });

    test('reading what was never written is null, not an error', () async {
      expect(await storage.get(StorageScope.shell, 'nothing'), isNull);
      expect(await storage.list(StorageScope.shared), isEmpty);
    });

    test('a listing carries sizes and versions but no bodies', () async {
      await storage.put(StorageScope.shell, 'a', bytes('xx'), contentType: 'text/plain');
      final rows = await storage.list(StorageScope.shell);
      expect(rows.single.key, 'a');
      expect(rows.single.size, 2);
      expect(rows.single.version, isNotEmpty);
    });

    test('a prefix narrows the listing — a string prefix, not a path segment', () async {
      await storage.put(StorageScope.shell, 'ui.theme', bytes('1'), contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'ui.scale', bytes('1'), contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'other', bytes('1'), contentType: 'text/plain');
      expect((await storage.list(StorageScope.shell, prefix: 'ui.')).length, 2);
    });
  });

  group('scopes cannot see each other', () {
    test('the same key in two scopes is two records', () async {
      await storage.put(StorageScope.shell, 'k', bytes('mine'), contentType: 'text/plain');
      await storage.put(StorageScope.shellOf('appplayer'), 'k', bytes('theirs'), contentType: 'text/plain');
      expect(utf8.decode((await storage.get(StorageScope.shell, 'k'))!.body), 'mine');
      expect(utf8.decode((await storage.get(StorageScope.shellOf('appplayer'), 'k'))!.body), 'theirs');
    });

    test('the scope travels on the wire as the contract spells it', () async {
      await storage.put(StorageScope.app('com.x'), 'k', bytes('1'), contentType: 'text/plain');
      expect(apps.seen.last.path, contains(Uri.encodeComponent('app/com.x')));
    });
  });

  group('conflict — detected, never resolved', () {
    test('a stale ifMatch is refused and hands back what is there now', () async {
      await storage.put(StorageScope.shell, 'k', bytes('server'), contentType: 'text/plain');
      await expectLater(
        storage.put(StorageScope.shell, 'k', bytes('mine'), contentType: 'text/plain', ifMatch: 'stale'),
        throwsA(isA<VersionConflict>().having(
          (e) => utf8.decode(e.current!.body), 'current body', 'server')),
      );
    });

    test('the matching version writes and mints a new one', () async {
      final first = await storage.put(StorageScope.shell, 'k', bytes('a'), contentType: 'text/plain');
      final second = await storage.put(StorageScope.shell, 'k', bytes('b'),
          contentType: 'text/plain', ifMatch: first.version);
      expect(second.version, isNot(first.version));
    });

    test('a delete with a stale version is refused too', () async {
      await storage.put(StorageScope.shell, 'k', bytes('a'), contentType: 'text/plain');
      await expectLater(
        storage.delete(StorageScope.shell, 'k', ifMatch: 'stale'),
        throwsA(isA<VersionConflict>()),
      );
    });
  });

  group('quota', () {
    test('a write past the limit names the scope and the shortfall', () async {
      apps = FakeApps(limit: 4);
      storage = HttpAccountStorage(apps.send, FakeTransfer(apps), sleep: (_) async {});
      await expectLater(
        storage.put(StorageScope.shell, 'k', bytes('12345'), contentType: 'text/plain'),
        throwsA(isA<QuotaExceeded>()
            .having((e) => e.scope, 'scope', StorageScope.shell)
            .having((e) => e.key, 'key', 'k')),
      );
    });

    test('usage reports families and both limits the server set', () async {
      final u = await storage.usage();
      expect(u.limit, 1000);
      expect(u.byScope.containsKey('shell'), isTrue);
      // The two mean opposite things: past the ceiling the route changes, past the limit it is refused.
      expect(u.inlineCeiling, 64);
      expect(u.maxBodyBytes, 1 << 20);
    });

    test('when the server states no limit it is 0 â not "unlimited" but "unknown", and the refusal speaks', () async {
      final storage = HttpAccountStorage(
        (_) async => const HttpReply(200, {'used': 0, 'limit': 10, 'byScope': {}, 'inlineCeiling': 64}),
        FakeTransfer(apps),
      );
      expect((await storage.usage()).maxBodyBytes, 0);
    });
  });

  group('a body past the inline ceiling', () {
    test('travels by ticket and comes back whole — the caller asked for `put`, not for a protocol', () async {
      final body = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final receipt = await storage.put(StorageScope.bundle('r1'), 'body', body,
          contentType: 'application/zip');
      expect(receipt.version, isNotEmpty);
      final got = await storage.get(StorageScope.bundle('r1'), 'body');
      expect(got!.body, body);
      expect(got.version, receipt.version);
    });

    test('the ticket is opened with size, never with the bytes', () async {
      await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip');
      final open = apps.seen.firstWhere((r) => r.method == 'PUT' && r.body!['size'] != null);
      expect(open.body!['body'], isNull);
      expect(open.body!['size'], 200);
    });

    test('the upload carries the content type the ticket was opened with', () async {
      await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip');
      expect(transfer.uploads.single.contentType, 'application/zip');
    });

    test('a listing shows the real size, and usage counts it', () async {
      await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip');
      expect((await storage.list(StorageScope.bundle('r1'))).single.size, 200);
      expect((await storage.usage()).used, 200);
    });

    test('overwriting a large record returns the NEW version, not the one still sitting there', () async {
      final first = await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200),
          contentType: 'application/zip');
      final second = await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(300),
          contentType: 'application/zip', ifMatch: first.version);
      expect(second.version, isNot(first.version));
      expect((await storage.get(StorageScope.bundle('r1'), 'b'))!.version, second.version);
    });

    test('bytes that landed without a record are not reported as saved', () async {
      // The server could not complete — no room, or another device wrote meanwhile.
      final t = FakeTransfer(apps, autoFinalize: false);
      final s2 = HttpAccountStorage(apps.send, t, sleep: (_) async {});
      await expectLater(
        s2.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip'),
        throwsA(isA<StorageUnavailable>()),
      );
      expect(t.uploads, hasLength(1)); // The bytes went. Still not reported as success.
    });

    test('a stale ifMatch is refused before anything is uploaded', () async {
      await storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip');
      await expectLater(
        storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200),
            contentType: 'application/zip', ifMatch: 'stale'),
        throwsA(isA<VersionConflict>().having((e) => e.current, 'current', isNull)),
      );
      expect(transfer.uploads, hasLength(1)); // The second one was not uploaded
    });

    test('no room is refused before the bytes go — that bandwidth is spent either way', () async {
      apps = FakeApps(limit: 100);
      transfer = FakeTransfer(apps);
      storage = HttpAccountStorage(apps.send, transfer, sleep: (_) async {});
      await expectLater(
        storage.put(StorageScope.bundle('r1'), 'b', Uint8List(200), contentType: 'application/zip'),
        throwsA(isA<QuotaExceeded>()),
      );
      expect(transfer.uploads, isEmpty);
    });

    test('past the hard ceiling nothing carries it — refused by name, before the network', () async {
      apps = FakeApps(maxBody: 500);
      transfer = FakeTransfer(apps);
      storage = HttpAccountStorage(apps.send, transfer, sleep: (_) async {});
      await storage.usage();
      final before = apps.seen.length;
      await expectLater(
        storage.put(StorageScope.bundle('r1'), 'b', Uint8List(600), contentType: 'application/zip'),
        throwsA(isA<BodyTooLarge>().having((e) => e.ceiling, 'ceiling', 500)),
      );
      expect(apps.seen.length, before);
      expect(transfer.uploads, isEmpty);
    });
  });

  group('failures the contract does not model', () {
    test('are not disguised as one of the three', () async {
      final storage = HttpAccountStorage(
          (_) async => const HttpReply(401, {'error': {'code': 'unauthorized', 'message': 'token expired'}}),
          FakeTransfer(apps));
      await expectLater(
        storage.put(StorageScope.shell, 'k', bytes('a'), contentType: 'text/plain'),
        throwsA(isA<StorageUnavailable>().having((e) => e.status, 'status', 401)),
      );
    });
  });

  group('timestamps', () {
    test('an unknown shape does not become "now" — a stale record would look fresh', () async {
      final storage = HttpAccountStorage((r) async => r.path == '/me/quota'
          ? const HttpReply(200, {'used': 0, 'limit': 10, 'byScope': {}, 'inlineCeiling': 64})
          : const HttpReply(200, {
              'body': '', 'contentType': 'text/plain', 'version': 'v1', 'updatedAt': {'weird': true},
            }), FakeTransfer(apps));
      final got = await storage.get(StorageScope.shell, 'k');
      expect(got!.updatedAt.millisecondsSinceEpoch, 0);
    });
  });
}
