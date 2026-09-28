/// The sync layer: hold a version, write against it, hand conflicts up.
///
/// Two devices are simulated by two [SyncedDocument]s over one storage, which
/// is what they actually are — the same record, two holders of a version, and
/// whichever writes second finds out.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/synced_document.dart';
import 'package:flutter_test/flutter_test.dart';

/// A set of installed app ids — the shape MOD-BUNDLE keeps, and one that
/// genuinely merges: two devices installing different apps should end with
/// both, and that is only decidable with the base to compare against.
final DocumentCodec<Set<String>> _installedCodec = DocumentCodec<Set<String>>(
  encode: (value) => utf8.encode(jsonEncode(value.toList()..sort())),
  decode: (record) =>
      (jsonDecode(utf8.decode(record.body)) as List<Object?>).cast<String>().toSet(),
  contentType: 'application/json',
);

/// Three-way set merge: keep what either side added, drop what either removed.
Set<String>? _mergeInstalled({
  required Set<String>? base,
  required Set<String> mine,
  required Set<String> theirs,
}) {
  final start = base ?? const <String>{};
  final removed = start.difference(mine).union(start.difference(theirs));
  return mine.union(theirs).difference(removed);
}

/// An owner that cannot reconcile — a single scalar, where there is no
/// answer that is not a choice.
final DocumentCodec<String> _themeCodec = DocumentCodec<String>(
  encode: utf8.encode,
  decode: (record) => utf8.decode(record.body),
  contentType: 'text/plain',
);

String? _cannotMerge({
  required String? base,
  required String mine,
  required String theirs,
}) =>
    null;

void main() {
  late InMemoryAccountStorage storage;

  setUp(() => storage = InMemoryAccountStorage());

  SyncedDocument<Set<String>> installedOn() => SyncedDocument<Set<String>>(
        storage: storage,
        scope: StorageScope.shell,
        key: 'installed',
        codec: _installedCodec,
        merge: _mergeInstalled,
      );

  group('a record nobody has written', () {
    test('loads as null, and the first write needs no version', () async {
      final device = installedOn();

      expect(await device.load(), isNull);
      expect(device.version, isNull);

      await device.save(<String>{'notes'});
      expect(await device.load(), <String>{'notes'});
    });
  });

  group('one device at a time', () {
    test('a write is readable by the other', () async {
      final desktop = installedOn();
      final web = installedOn();

      await desktop.load();
      await desktop.save(<String>{'notes', 'draw'});

      expect(await web.load(), <String>{'notes', 'draw'});
    });

    test('successive writes from the same holder do not conflict', () async {
      final desktop = installedOn();
      await desktop.load();

      await desktop.save(<String>{'notes'});
      await desktop.save(<String>{'notes', 'draw'});
      await desktop.save(<String>{'notes', 'draw', 'calc'});

      expect(await installedOn().load(), <String>{'notes', 'draw', 'calc'});
    });
  });

  group('two devices, one record', () {
    test('the second write merges instead of overwriting', () async {
      // The case that matters: both were offline, both installed something.
      // Last-write-wins loses one of them silently.
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes'});
      await web.load();

      await desktop.save(<String>{'notes', 'draw'});
      final stored = await web.save(<String>{'notes', 'calc'});

      expect(stored, <String>{'notes', 'draw', 'calc'});
      expect(await installedOn().load(), <String>{'notes', 'draw', 'calc'});
    });

    test('a removal by one is not undone by the other', () async {
      // Without the base this is undecidable: "absent here, present there" is
      // an addition read backwards.
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes', 'draw'});
      await web.load();

      await desktop.save(<String>{'notes'}); // uninstalled draw
      await web.save(<String>{'notes', 'draw', 'calc'}); // added calc

      expect(await installedOn().load(), <String>{'notes', 'calc'});
    });

    test('the merged value is what the caller gets back', () async {
      // What is on screen has to become what is in the account, so the caller
      // has to be told the write did not store what it asked for.
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes'});
      await web.load();
      await desktop.save(<String>{'notes', 'draw'});

      expect(await web.save(<String>{'notes'}), <String>{'notes', 'draw'});
    });

    test('after merging, the next write does not conflict again', () async {
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes'});
      await web.load();
      await desktop.save(<String>{'notes', 'draw'});
      await web.save(<String>{'notes', 'calc'});

      await web.save(<String>{'notes', 'draw', 'calc', 'mail'});
      expect(await installedOn().load(),
          <String>{'notes', 'draw', 'calc', 'mail'});
    });
  });

  group('when the owner cannot reconcile', () {
    SyncedDocument<String> themeOn() => SyncedDocument<String>(
          storage: storage,
          scope: StorageScope.common,
          key: 'theme',
          codec: _themeCodec,
          merge: _cannotMerge,
        );

    test('the person is asked, and both versions come with the question',
        () async {
      final desktop = themeOn();
      final web = themeOn();
      await desktop.load();
      await desktop.save('light');
      await web.load();
      await desktop.save('dark');

      try {
        await web.save('sepia');
        fail('an unmergeable conflict should not have been decided here');
      } on MergeNeedsPerson<String> catch (asked) {
        expect(asked.mine, 'sepia');
        expect(asked.theirs, 'dark');
        expect(asked.base, 'light');
        expect(asked.key, 'theme');
      }
    });

    test('and nothing was written while asking', () async {
      final desktop = themeOn();
      final web = themeOn();
      await desktop.load();
      await desktop.save('light');
      await web.load();
      await desktop.save('dark');

      await expectLater(
          web.save('sepia'), throwsA(isA<MergeNeedsPerson<String>>()));
      expect(await themeOn().load(), 'dark');
    });

    test('what the person chose is then written', () async {
      final desktop = themeOn();
      final web = themeOn();
      await desktop.load();
      await desktop.save('light');
      await web.load();
      await desktop.save('dark');
      await expectLater(
          web.save('sepia'), throwsA(isA<MergeNeedsPerson<String>>()));

      await web.resolveAs('sepia');

      expect(await themeOn().load(), 'sepia');
      // And the holder is current again, so the next write does not re-ask a
      // question that was just answered.
      await web.save('sepia-high-contrast');
      expect(await themeOn().load(), 'sepia-high-contrast');
    });
  });

  group('a record with one writer by contract', () {
    SyncedDocument<Set<String>> deviceFacts() =>
        SyncedDocument<Set<String>>.singleWriter(
          storage: storage,
          scope: StorageScope.device('desk-1'),
          key: 'installed',
          codec: _installedCodec,
        );

    test('writes as usual while the rule holds', () async {
      final device = deviceFacts();
      await device.load();

      await device.save(<String>{'notes'});
      await device.save(<String>{'notes', 'draw'});

      expect(await deviceFacts().load(), <String>{'notes', 'draw'});
    });

    test('a second writer is reported, not merged', () async {
      // Merging here would paper over something writing where it must not,
      // and the symptom would surface later as facts about a device that
      // device never had.
      final owner = deviceFacts();
      final intruder = deviceFacts();
      await owner.load();
      await owner.save(<String>{'notes'});
      await intruder.load();
      await owner.save(<String>{'notes', 'draw'});

      await expectLater(
        intruder.save(<String>{'notes', 'calc'}),
        throwsA(isA<SingleWriterViolated>()),
      );
      expect(await deviceFacts().load(), <String>{'notes', 'draw'});
    });
  });

  group('the record went away underneath', () {
    test('a write after somebody deleted it becomes a first write', () async {
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes'});
      await web.load();
      await desktop.delete();

      expect(await web.save(<String>{'notes', 'calc'}),
          <String>{'notes', 'calc'});
      expect(await installedOn().load(), <String>{'notes', 'calc'});
    });

    test('deleting is conditional on the version held', () async {
      final desktop = installedOn();
      final web = installedOn();
      await desktop.load();
      await desktop.save(<String>{'notes'});
      await web.load();
      await desktop.save(<String>{'notes', 'draw'});

      await expectLater(web.delete(), throwsA(isA<VersionConflict>()));
      expect(await installedOn().load(), <String>{'notes', 'draw'});
    });
  });

  group('losing the race repeatedly', () {
    test('gives up naming the record rather than looping', () async {
      // A retry loop with no bound hides something writing in a loop; the
      // symptom would be a hang with nothing pointing at the cause.
      final web = SyncedDocument<Set<String>>(
        storage: _AlwaysConflicting(storage),
        scope: StorageScope.shell,
        key: 'installed',
        codec: _installedCodec,
        merge: _mergeInstalled,
        maxAttempts: 3,
      );

      try {
        await web.save(<String>{'notes'});
        fail('the write should have given up');
      } on SyncGaveUp catch (gaveUp) {
        expect(gaveUp.attempts, 3);
        expect(gaveUp.key, 'installed');
      }
    });
  });

  group('a full account', () {
    test('is reported straight through, not swallowed as a conflict', () async {
      final small = InMemoryAccountStorage(limit: 8);
      final device = SyncedDocument<Set<String>>(
        storage: small,
        scope: StorageScope.shell,
        key: 'installed',
        codec: _installedCodec,
        merge: _mergeInstalled,
      );

      await expectLater(
        device.save(<String>{'notes', 'draw', 'calculator'}),
        throwsA(isA<QuotaExceeded>()),
      );
    });
  });
}

/// Storage where somebody always writes first.
///
/// Every conditional write loses, so the retry bound is what ends it.
class _AlwaysConflicting implements AccountStorage {
  _AlwaysConflicting(this._inner);

  final InMemoryAccountStorage _inner;
  int _round = 0;

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async {
    // Somebody else's write lands between the read and this one, every time.
    await _inner.put(scope, key, utf8.encode('["round-${_round++}"]'),
        contentType: contentType);
    if (ifMatch == null) {
      // Even the unconditional first attempt is made to lose, by writing
      // again after it — the point is to exercise the bound, not the API.
      throw VersionConflict(
        scope: scope,
        key: key,
        current: await _inner.get(scope, key),
      );
    }
    return _inner.put(scope, key, body,
        contentType: contentType, ifMatch: ifMatch);
  }

  @override
  Future<StoredRecord?> get(StorageScope scope, String key) =>
      _inner.get(scope, key);

  @override
  Future<List<RecordInfo>> list(StorageScope scope, {String? prefix}) =>
      _inner.list(scope, prefix: prefix);

  @override
  Future<void> delete(StorageScope scope, String key, {String? ifMatch}) =>
      _inner.delete(scope, key, ifMatch: ifMatch);

  @override
  Future<StorageUsage> usage() => _inner.usage();
}
