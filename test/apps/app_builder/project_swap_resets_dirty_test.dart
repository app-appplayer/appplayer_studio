/// Every place the App Builder shell swaps in another project also resets
/// the shell's unsaved flag to the new canonical's state. The external-change
/// check raises that flag on the shell alone, so the canonical's own dirty
/// event never clears it: opening another project after an outside edit
/// showed the new, untouched project as unsaved.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each project swap resets the unsaved flag', () {
    final src =
        File(
          'lib/src/apps/app_builder/feat/shell_layout.dart',
        ).readAsStringSync();
    final swaps =
        RegExp(
          r'final previous = _project;[\s\S]*?setState\(\(\) \{([\s\S]*?)\n\s*\}\);',
        ).allMatches(src).toList();
    expect(swaps, hasLength(5));
    for (final m in swaps) {
      final body = m.group(1)!;
      expect(body, contains('_project = project;'));
      expect(body, contains('_dirty = widget.canonical.isDirty;'));
      expect(body, contains('_channelDirty.clear();'));
    }
  });
}
