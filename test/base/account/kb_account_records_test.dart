/// A bundle's `kb` records land in the account's `app/<appId>` scope, one
/// record per key in the layout the kernel gives (`kb/<key>`, platform spec 20
/// §2.1.2), and the account's refusals keep their names — none of them is
/// mistaken for an unreachable account.
library;

import 'dart:typed_data';

import 'package:appplayer_studio/src/base/account/account_storage.dart';
import 'package:appplayer_studio/src/base/account/http_account_storage.dart'
    show StorageUnavailable;
import 'package:appplayer_studio/src/base/account/in_memory_account_storage.dart';
import 'package:appplayer_studio/src/base/account/kb_account_records.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show
        AccountKbRecordStore,
        BundleKbStore,
        InMemoryKvStoragePort,
        KbAccountConflict,
        KbError;
import 'package:flutter_test/flutter_test.dart';

/// Account storage that answers one status for every write, as the server does.
class _AnsweringStorage extends InMemoryAccountStorage {
  _AnsweringStorage(this.status, this.message);

  final int status;
  final String message;

  @override
  Future<WriteReceipt> put(
    StorageScope scope,
    String key,
    Uint8List body, {
    required String contentType,
    String? ifMatch,
  }) async =>
      throw StorageUnavailable(status, message);
}

void main() {
  const appId = 'listing:L1';
  late InMemoryAccountStorage storage;
  late AccountStorageKbRecords records;

  String stored(String key) => AccountKbRecordStore.accountKeyOf(key);

  setUp(() {
    storage = InMemoryAccountStorage();
    records = AccountStorageKbRecords(storage);
  });

  test('each key is its own record in app/<appId>, under the key it was given', () async {
    await records.write(appId, stored('notes/a'), {'n': 1});
    await records.write(appId, stored('메모 1'), 2);

    final keys = (await storage.list(StorageScope.app(appId))).map((e) => e.key);
    expect(keys, containsAll(<String>['kb/notes/a', 'kb/:EB:A9:94:EB:AA:A8:201']));
    expect((await records.read(appId, stored('notes/a')))?.value, {'n': 1});
    expect((await records.list(appId, stored('notes/'))).map((r) => r.key), ['kb/notes/a']);
  });

  test('a stale version is a conflict carrying what the account holds', () async {
    final first = await records.write(appId, stored('a'), 'one');
    await records.write(appId, stored('a'), 'two', ifMatch: first);

    await expectLater(
      records.write(appId, stored('a'), 'three', ifMatch: first),
      throwsA(isA<KbAccountConflict>().having((c) => c.current?.value, 'current', 'two')),
    );
  });

  test('removal answers whether a record was there', () async {
    await records.write(appId, stored('a'), 1);
    expect(await records.remove(appId, stored('a')), isTrue);
    expect(await records.remove(appId, stored('a')), isFalse);
  });

  group('the account\'s refusals are refusals', () {
    Future<void> refusedAs(int status, String message, String code) => expectLater(
          AccountStorageKbRecords(_AnsweringStorage(status, message))
              .write(appId, stored('a'), 1),
          throwsA(isA<KbError>().having((e) => e.code, 'code', code)),
        );

    test('a key it does not accept', () => refusedAs(400, 'invalid storage key', KbError.invalidKey));

    test('a scope it does not accept', () =>
        refusedAs(400, 'invalid storage scope', KbError.unavailable));

    test('any other request it turns down', () => refusedAs(404, 'not found', KbError.unavailable));

    test('an expired sign-in, a timeout, throttling and a server fault stay unreachable', () async {
      for (final status in [0, 401, 403, 408, 429, 500, 503]) {
        await expectLater(
          AccountStorageKbRecords(_AnsweringStorage(status, 'x')).write(appId, stored('a'), 1),
          throwsA(isA<StorageUnavailable>()),
          reason: '$status',
        );
      }
    });

    test('a refused write is not queued: the bundle hears it and nothing waits', () async {
      final kv = InMemoryKvStoragePort();
      final kb = BundleKbStore(
        appId: appId,
        records: AccountKbRecordStore(
          account: AccountStorageKbRecords(_AnsweringStorage(400, 'invalid storage key')),
          kv: kv,
        ),
      );
      await expectLater(kb.put('a', 1), throwsA(isA<KbError>()));
      expect(await kv.keys(prefix: 'app/${Uri.encodeComponent(appId)}/kbq/'), isEmpty);
    });
  });

  test('a bundle store on the account keeps the contract shapes end to end', () async {
    final kb = BundleKbStore(
      appId: appId,
      records: AccountKbRecordStore(account: records, kv: InMemoryKvStoragePort()),
    );
    expect(await kb.put('메모 1', {'n': 1}), {'ok': true});
    expect(await kb.get('메모 1'), {'n': 1});
    expect(await kb.list(), [
      {'key': '메모 1', 'value': {'n': 1}},
    ]);
    expect(await kb.delete('메모 1'), {'removed': true});
    expect(await storage.list(StorageScope.app(appId)), isEmpty);
  });
}
