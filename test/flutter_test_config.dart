import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/util/log.dart';

/// Every test in this package writes Ops log records to a throwaway file.
/// Suites boot Ops projects in temp folders; without this their boot lines
/// landed in the real `~/.makemind-ops/boot.log` of whoever ran the suite.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final dir = Directory.systemTemp.createTempSync('ops_log_');
  OpsLog.redirectTo(File('${dir.path}/boot.log'));
  await testMain();
}
