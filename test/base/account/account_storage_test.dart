/// The rules of `specs/platform/20-account-storage.md`, pinned.
///
/// This tests a fake, which is worth being clear about: it does not prove any
/// server behaves this way. What it proves is that the shape the modules above
/// are written against is the shape the contract describes — so when the real
/// implementation arrives, this file is the checklist it has to pass, and the
/// layers above do not have to change.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryAccountStorage storage;

  setUp(() => storage = InMemoryAccountStorage());

  Uint8List bytes(String text) => utf8.encode(text);

  group('scopes are boundaries, not strings', () {
    test('each one addresses what the contract says it does', () {
      expect(StorageScope.common.wire, 'shell/common');
      expect(StorageScope.shell.wire, 'shell/studio');
      expect(StorageScope.shellOf('appplayer').wire, 'shell/appplayer');
      expect(StorageScope.app('com.example.notes').wire,
          'app/com.example.notes');
      expect(StorageScope.knowledge('kb1').wire, 'knowledge/kb1');
      expect(StorageScope.device('desk-1').wire, 'device/desk-1');
      expect(StorageScope.bundle('mine.mbd').wire, 'bundle/mine.mbd');
      expect(StorageScope.shared.wire, 'shared');
    });

    test('two scopes naming the same place are the same scope', () {
      // They are used as map keys and compared across module boundaries, so
      // identity has to follow the address rather than the object.
      expect(StorageScope.app('a'), StorageScope.app('a'));
      expect(StorageScope.app('a').hashCode, StorageScope.app('a').hashCode);
      expect(StorageScope.app('a'), isNot(StorageScope.app('b')));
      expect(StorageScope.shellOf('studio'), StorageScope.shell);
    });
  });

  group('reading what was never written', () {
    test('is null, not a failure', () async {
      expect(await storage.get(StorageScope.shell, 'layout'), isNull);
    });

    test('and an untouched scope lists empty', () async {
      expect(await storage.list(StorageScope.shared), isEmpty);
    });
  });

  group('a record round-trips', () {
    test('body, label, and version come back', () async {
      final receipt = await storage.put(
        StorageScope.shell,
        'layout',
        bytes('{"icons":[]}'),
        contentType: 'application/json',
      );

      final record = await storage.get(StorageScope.shell, 'layout');
      expect(utf8.decode(record!.body), '{"icons":[]}');
      expect(record.contentType, 'application/json');
      expect(record.version, receipt.version);
    });

    test('the server does not read the body', () async {
      // Opaque means opaque: bytes that are not JSON, stored under a JSON
      // label, come back unchanged. Anything that parsed on the way through
      // would refuse this.
      final raw = Uint8List.fromList(<int>[0, 1, 2, 255, 254]);
      await storage.put(StorageScope.bundle('mine.mbd'), 'body', raw,
          contentType: 'application/json');

      final record = await storage.get(StorageScope.bundle('mine.mbd'), 'body');
      expect(record!.body, raw);
    });

    test('what a caller does to the bytes it read does not reach storage',
        () async {
      await storage.put(StorageScope.shell, 'layout', bytes('original'),
          contentType: 'text/plain');

      final first = await storage.get(StorageScope.shell, 'layout');
      first!.body[0] = 0x58;

      final second = await storage.get(StorageScope.shell, 'layout');
      expect(utf8.decode(second!.body), 'original');
    });

    test('a listing describes without fetching', () async {
      await storage.put(StorageScope.shared, 'b.txt', bytes('bbbb'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shared, 'a.txt', bytes('aa'),
          contentType: 'text/plain');

      final listing = await storage.list(StorageScope.shared);
      expect(listing.map((r) => r.key), <String>['a.txt', 'b.txt']);
      expect(listing.first.size, 2);
      expect(listing.first.version, isNotEmpty);
    });

    test('a prefix narrows a listing', () async {
      for (final key in <String>['ui/theme', 'ui/lang', 'net/proxy']) {
        await storage.put(StorageScope.common, key, bytes('x'),
            contentType: 'text/plain');
      }

      final listing = await storage.list(StorageScope.common, prefix: 'ui/');
      expect(listing.map((r) => r.key), <String>['ui/lang', 'ui/theme']);
    });
  });

  group('scopes cannot see each other', () {
    test('the same key in two scopes is two records', () async {
      await storage.put(StorageScope.app('a'), 'state', bytes('from-a'),
          contentType: 'text/plain');
      await storage.put(StorageScope.app('b'), 'state', bytes('from-b'),
          contentType: 'text/plain');

      expect(
        utf8.decode((await storage.get(StorageScope.app('a'), 'state'))!.body),
        'from-a',
      );
      expect(
        utf8.decode((await storage.get(StorageScope.app('b'), 'state'))!.body),
        'from-b',
      );
    });

    test('one app does not list another app', () async {
      await storage.put(StorageScope.app('b'), 'secret', bytes('x'),
          contentType: 'text/plain');

      expect(await storage.list(StorageScope.app('a')), isEmpty);
    });

    test('one product does not see another product\'s shell', () async {
      // The reason shells are per product: a layout arriving in Studio is
      // exactly what a shared shell bucket would do (the other way round here).
      await storage.put(StorageScope.shell, 'layout', bytes('desktop-icons'),
          contentType: 'text/plain');

      expect(await storage.list(StorageScope.shellOf('appplayer')), isEmpty);
    });

    test('but what crosses products is meant to', () async {
      // The two deliberate exceptions. An app's data is the app's, whichever
      // product opened it; taste belongs to the person.
      await storage.put(StorageScope.app('notes'), 'doc', bytes('body'),
          contentType: 'text/plain');
      await storage.put(StorageScope.common, 'theme', bytes('dark'),
          contentType: 'text/plain');

      expect(await storage.get(StorageScope.app('notes'), 'doc'), isNotNull);
      expect(await storage.get(StorageScope.common, 'theme'), isNotNull);
    });
  });

  group('conflict — detected, never resolved', () {
    test('a write on a stale version is refused', () async {
      final first = await storage.put(
          StorageScope.shell, 'layout', bytes('one'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'layout', bytes('two'),
          contentType: 'text/plain', ifMatch: first.version);

      expect(
        () => storage.put(StorageScope.shell, 'layout', bytes('three'),
            contentType: 'text/plain', ifMatch: first.version),
        throwsA(isA<VersionConflict>()),
      );
    });

    test('and the refusal carries what is there now', () async {
      // The heart of the contract. Without the current body the client has to
      // go read again before it can merge, and whatever changes in between
      // puts it right back here.
      final first = await storage.put(
          StorageScope.shell, 'layout', bytes('one'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'layout', bytes('somebody else'),
          contentType: 'text/plain', ifMatch: first.version);

      try {
        await storage.put(StorageScope.shell, 'layout', bytes('mine'),
            contentType: 'text/plain', ifMatch: first.version);
        fail('the stale write should have been refused');
      } on VersionConflict catch (conflict) {
        expect(utf8.decode(conflict.current!.body), 'somebody else');
        expect(conflict.scope, StorageScope.shell);
        expect(conflict.key, 'layout');
      }
    });

    test('a refused write changes nothing', () async {
      final first = await storage.put(
          StorageScope.shell, 'layout', bytes('one'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'layout', bytes('two'),
          contentType: 'text/plain', ifMatch: first.version);

      await expectLater(
        storage.put(StorageScope.shell, 'layout', bytes('three'),
            contentType: 'text/plain', ifMatch: first.version),
        throwsA(isA<VersionConflict>()),
      );
      expect(
        utf8.decode((await storage.get(StorageScope.shell, 'layout'))!.body),
        'two',
      );
    });

    test('a first write claiming a version is refused', () async {
      // ifMatch against nothing means the writer believes it read something.
      // It did not, and letting it through would overwrite whatever arrives
      // between now and then.
      expect(
        () => storage.put(StorageScope.shell, 'layout', bytes('one'),
            contentType: 'text/plain', ifMatch: 'v1'),
        throwsA(isA<VersionConflict>()),
      );
    });

    test('a conflict with a deleted record says so rather than inventing one',
        () async {
      final first = await storage.put(
          StorageScope.shell, 'layout', bytes('one'),
          contentType: 'text/plain');
      await storage.delete(StorageScope.shell, 'layout');

      try {
        await storage.put(StorageScope.shell, 'layout', bytes('two'),
            contentType: 'text/plain', ifMatch: first.version);
        fail('the write should have been refused');
      } on VersionConflict catch (conflict) {
        expect(conflict.current, isNull);
      }
    });

    test('no ifMatch overwrites — the escape hatch is explicit', () async {
      await storage.put(StorageScope.shell, 'layout', bytes('one'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'layout', bytes('forced'),
          contentType: 'text/plain');

      expect(
        utf8.decode((await storage.get(StorageScope.shell, 'layout'))!.body),
        'forced',
      );
    });

    test('a version is never reissued for the same bytes', () async {
      // A version derived from the body would collide with itself: write A,
      // write B, write A again, and a writer holding the first version would
      // be allowed through a write that should have been refused.
      final a = await storage.put(StorageScope.shell, 'k', bytes('A'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shell, 'k', bytes('B'),
          contentType: 'text/plain', ifMatch: a.version);
      final back = await storage.put(StorageScope.shell, 'k', bytes('A'),
          contentType: 'text/plain');

      expect(back.version, isNot(a.version));
      expect(
        () => storage.put(StorageScope.shell, 'k', bytes('C'),
            contentType: 'text/plain', ifMatch: a.version),
        throwsA(isA<VersionConflict>()),
      );
    });
  });

  group('delete', () {
    test('removes, and removing again is not an error', () async {
      await storage.put(StorageScope.shared, 'doc', bytes('x'),
          contentType: 'text/plain');
      await storage.delete(StorageScope.shared, 'doc');

      expect(await storage.get(StorageScope.shared, 'doc'), isNull);
      await storage.delete(StorageScope.shared, 'doc');
      await storage.delete(StorageScope.shared, 'never-written');
    });

    test('a conditional delete on a stale version is refused', () async {
      final first = await storage.put(StorageScope.shared, 'doc', bytes('one'),
          contentType: 'text/plain');
      await storage.put(StorageScope.shared, 'doc', bytes('edited'),
          contentType: 'text/plain', ifMatch: first.version);

      await expectLater(
        storage.delete(StorageScope.shared, 'doc', ifMatch: first.version),
        throwsA(isA<VersionConflict>()),
      );
      expect(await storage.get(StorageScope.shared, 'doc'), isNotNull);
    });
  });

  group('quota', () {
    test('reports what is used, and by which scope', () async {
      await storage.put(StorageScope.shell, 'layout', bytes('12345'),
          contentType: 'text/plain');
      await storage.put(StorageScope.app('notes'), 'doc', bytes('123'),
          contentType: 'text/plain');

      final usage = await storage.usage();
      expect(usage.used, 8);
      expect(usage.byScope['shell/studio'], 5);
      expect(usage.byScope['app/notes'], 3);
    });

    test('a full account refuses the write and names it', () async {
      final small = InMemoryAccountStorage(limit: 10);
      await small.put(StorageScope.shell, 'layout', bytes('12345678'),
          contentType: 'text/plain');

      try {
        await small.put(StorageScope.app('notes'), 'doc', bytes('12345'),
            contentType: 'text/plain');
        fail('the write should not have fit');
      } on QuotaExceeded catch (full) {
        // "Saving failed" leaves nobody able to act. The scope, the key, and
        // what is using the space are what make it actionable.
        expect(full.scope, StorageScope.app('notes'));
        expect(full.key, 'doc');
        expect(full.needed, 3);
        expect(full.usage.byScope['shell/studio'], 8);
      }
    });

    test('full stops writing, not reading', () async {
      final small = InMemoryAccountStorage(limit: 10);
      await small.put(StorageScope.shell, 'layout', bytes('1234567890'),
          contentType: 'text/plain');

      await expectLater(
        small.put(StorageScope.shared, 'doc', bytes('x'),
            contentType: 'text/plain'),
        throwsA(isA<QuotaExceeded>()),
      );
      expect(await small.get(StorageScope.shell, 'layout'), isNotNull);
      expect(await small.list(StorageScope.shell), hasLength(1));
      expect((await small.usage()).isFull, isTrue);
    });

    test('a rewrite pays only for what it adds', () async {
      // Otherwise saving the same document twice costs twice, and an account
      // fills up without holding anything more.
      final small = InMemoryAccountStorage(limit: 10);
      await small.put(StorageScope.shell, 'layout', bytes('12345678'),
          contentType: 'text/plain');
      await small.put(StorageScope.shell, 'layout', bytes('87654321'),
          contentType: 'text/plain');

      expect((await small.usage()).used, 8);
    });

    test('a shrinking rewrite fits even when the account is full', () async {
      final small = InMemoryAccountStorage(limit: 10);
      await small.put(StorageScope.shell, 'layout', bytes('1234567890'),
          contentType: 'text/plain');
      await small.put(StorageScope.shell, 'layout', bytes('1'),
          contentType: 'text/plain');

      expect((await small.usage()).used, 1);
    });

    test('deleting makes room', () async {
      final small = InMemoryAccountStorage(limit: 10);
      await small.put(StorageScope.shell, 'layout', bytes('1234567890'),
          contentType: 'text/plain');
      await small.delete(StorageScope.shell, 'layout');
      await small.put(StorageScope.shared, 'doc', bytes('12345'),
          contentType: 'text/plain');

      expect((await small.usage()).used, 5);
    });
  });

  group('a body too large to hand over inline', () {
    test('is refused by name, not truncated', () async {
      // Truncating stores a loss and reports a success. The refusal says
      // which record and what the ceiling is, so the caller can send it the
      // other way instead.
      final capped = InMemoryAccountStorage(inlineCeiling: 8);

      try {
        await capped.put(StorageScope.bundle('mine.mbd'), 'body',
            bytes('123456789'),
            contentType: 'application/octet-stream');
        fail('the body should not have been taken inline');
      } on BodyTooLarge catch (big) {
        expect(big.scope, StorageScope.bundle('mine.mbd'));
        expect(big.key, 'body');
        expect(big.size, 9);
        expect(big.ceiling, 8);
      }
    });

    test('and nothing was stored', () async {
      final capped = InMemoryAccountStorage(inlineCeiling: 8);
      await expectLater(
        capped.put(StorageScope.bundle('m'), 'body', bytes('123456789'),
            contentType: 'application/octet-stream'),
        throwsA(isA<BodyTooLarge>()),
      );

      expect(await capped.get(StorageScope.bundle('m'), 'body'), isNull);
    });

    test('the ceiling is reported, not a constant the client holds', () async {
      // A client constant is wrong first on the day the server changes it.
      expect((await InMemoryAccountStorage(inlineCeiling: 8).usage())
          .inlineCeiling, 8);
      expect((await InMemoryAccountStorage().usage()).inlineCeiling, 0);
    });

    test('too large outranks a stale version', () async {
      // Reporting the conflict first would send the caller off to merge
      // something it then still could not store.
      final capped = InMemoryAccountStorage(inlineCeiling: 8);
      await capped.put(StorageScope.bundle('m'), 'body', bytes('1'),
          contentType: 'application/octet-stream');

      await expectLater(
        capped.put(StorageScope.bundle('m'), 'body', bytes('123456789'),
            contentType: 'application/octet-stream', ifMatch: 'stale'),
        throwsA(isA<BodyTooLarge>()),
      );
    });
  });

  group('json bodies', () {
    test('round-trip with one agreed label', () async {
      final encoded = jsonBody(<String, Object?>{'theme': 'dark'});
      await storage.put(StorageScope.common, 'prefs', encoded.body,
          contentType: encoded.contentType);

      final record = await storage.get(StorageScope.common, 'prefs');
      expect(record!.contentType, 'application/json');
      expect(decodeJsonBody(record), <String, Object?>{'theme': 'dark'});
    });

    test('bytes that are not the JSON they claim throw rather than read null',
        () async {
      // Null is what an absent record reads as. A corrupt one is not absent,
      // and answering the same for both hides the fault.
      await storage.put(StorageScope.common, 'prefs', bytes('not json'),
          contentType: 'application/json');

      final record = await storage.get(StorageScope.common, 'prefs');
      expect(() => decodeJsonBody(record!), throwsFormatException);
    });
  });
}
