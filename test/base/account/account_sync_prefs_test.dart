/// The device's sync facts: the id is made once and kept, the switch is
/// remembered, and neither lives in `settings.json` where a dialog Save would
/// write an old copy back.
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/account/account_sync_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('account_sync_prefs_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('the device id is made once, written, and kept', () {
    final first = AccountSyncPrefs.loadOrCreate(root.path);
    expect(first.deviceId, hasLength(32));
    expect(File(AccountSyncPrefs.pathIn(root.path)).existsSync(), isTrue);

    final again = AccountSyncPrefs.loadOrCreate(root.path);
    expect(again.deviceId, first.deviceId);
  });

  test('sync is off until turned on, and the switch is remembered', () {
    final prefs = AccountSyncPrefs.loadOrCreate(root.path);
    expect(prefs.syncEnabled, isFalse);

    prefs.setSyncEnabled(true);
    final again = AccountSyncPrefs.loadOrCreate(root.path);
    expect(again.syncEnabled, isTrue);
    expect(again.deviceId, prefs.deviceId);
  });

  test('an unreadable file gives a new id rather than no device', () {
    File(AccountSyncPrefs.pathIn(root.path)).writeAsStringSync('not json');
    final prefs = AccountSyncPrefs.loadOrCreate(root.path);
    expect(prefs.deviceId, hasLength(32));
    expect(prefs.syncEnabled, isFalse);
    expect(
      AccountSyncPrefs.loadOrCreate(root.path).deviceId,
      prefs.deviceId,
    );
  });

  test('the settings file is not touched', () {
    AccountSyncPrefs.loadOrCreate(root.path).setSyncEnabled(true);
    expect(File('${root.path}/settings.json').existsSync(), isFalse);
  });
}
