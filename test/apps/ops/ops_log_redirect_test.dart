/// Ops log records follow a redirect, so a test run never writes the real
/// `~/.makemind-ops/boot.log` (the package test config redirects every suite).
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/util/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the suite does not log to the home directory', () {
    final home = Platform.environment['HOME'] ?? '';
    expect(
      OpsLog.logFile.path,
      isNot(p.join(home, '.makemind-ops', 'boot.log')),
      reason: 'flutter_test_config.dart must redirect before tests run',
    );
  });

  test('records land in the redirected file', () {
    final previous = OpsLog.logFile;
    final dir = Directory.systemTemp.createTempSync('ops_log_redirect_');
    addTearDown(() {
      OpsLog.redirectTo(previous);
      dir.deleteSync(recursive: true);
    });
    final file = File(p.join(dir.path, 'nested', 'boot.log'));
    OpsLog.redirectTo(file);

    OpsLog.boot('init', 'redirect check');

    expect(file.readAsStringSync(), contains('[boot][init] redirect check'));
  });
}
