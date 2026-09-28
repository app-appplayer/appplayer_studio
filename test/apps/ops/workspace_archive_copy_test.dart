/// The workspace list's remove action says what it does. `workspace_delete`
/// archives by default (data kept, restorable), but the dialog promised
/// that the directory and KV partition were removed and "cannot be undone".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src =
      File(
        'lib/src/apps/ops/ui/workspace/workspace_list_pane.dart',
      ).readAsStringSync();

  test('the dialog and menu speak of archiving', () {
    expect(src, contains("Text('Archive workspace')"));
    expect(src, contains('can be restored'));
    expect(src, isNot(contains('cannot be undone')));
    expect(src, isNot(contains('KV partition are removed')));
  });

  test('the call asks for archive explicitly', () {
    expect(src, contains("'mode': 'archive'"));
  });
}
