/// Form Builder answers `studio.project.new` / `open` in the shape the other
/// apps use — `{ok, projectPath, projectName}` — instead of only
/// `projectRoot`, so one caller reads every app the same way.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('project slot result carries projectPath and projectName', () {
    final src =
        File('lib/src/apps/form_builder/ui/form_shell.dart').readAsStringSync();
    expect(src, contains("'projectPath': dir"));
    expect(src, contains("'projectName': p.basename(dir)"));
  });
}
