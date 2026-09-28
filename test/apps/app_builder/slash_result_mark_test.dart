/// A slash-command line marks the verdict, not just that the tool ran:
/// "✓ health_check · health · fail · 2 blocking" read as a pass.
library;

import 'dart:convert';

import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';
import 'package:flutter_test/flutter_test.dart';

BuildToolResult _ok(Map<String, Object?>? payload) => BuildToolResult.success(
  message: 'm',
  payload: payload == null ? null : jsonEncode(payload),
);

void main() {
  test('failing verdicts get ⚠', () {
    expect(slashResultMark(_ok({'status': 'fail'})), '⚠');
    expect(slashResultMark(_ok({'status': 'blocked'})), '⚠');
    expect(slashResultMark(_ok({'status': 'incomplete'})), '⚠');
    expect(slashResultMark(_ok({'ready': false})), '⚠');
  });

  test('passing or verdict-free results get ✓', () {
    expect(slashResultMark(_ok({'status': 'pass'})), '✓');
    expect(slashResultMark(_ok({'ready': true})), '✓');
    expect(slashResultMark(_ok({'grade': 'A'})), '✓');
    expect(slashResultMark(_ok(null)), '✓');
  });

  test('a tool that did not run gets ✗', () {
    expect(slashResultMark(BuildToolResult.failure('nope')), '✗');
  });
}
