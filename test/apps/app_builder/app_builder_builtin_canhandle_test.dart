/// `AppBuilderBuiltInApp.canHandle` — accepts a bundle path when either
/// (a) the `.builtin_app_builder` marker file exists, OR
/// (b) a `project.apbproj` project file exists at the root.
/// Refuses an absent or empty directory.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/apps.dart';

void main() {
  group('AppBuilderBuiltInApp.canHandle', () {
    const app = AppBuilderBuiltInApp();
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('app_builder_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('false when path does not exist', () {
      expect(app.canHandle('/nonexistent/path/foo'), isFalse);
    });

    test('false on empty directory (no marker, no project file)', () {
      expect(app.canHandle(tmp.path), isFalse);
    });

    test('true when `.builtin_app_builder` marker exists', () {
      final marker = File(p.join(tmp.path, '.builtin_app_builder'));
      marker.writeAsStringSync('');
      expect(app.canHandle(tmp.path), isTrue);
    });

    test('true when `project.apbproj` exists', () {
      final proj = File(p.join(tmp.path, 'project.apbproj'));
      proj.writeAsStringSync('{}');
      expect(app.canHandle(tmp.path), isTrue);
    });

    test('true when both marker and project file exist', () {
      File(p.join(tmp.path, '.builtin_app_builder')).writeAsStringSync('');
      File(p.join(tmp.path, 'project.apbproj')).writeAsStringSync('{}');
      expect(app.canHandle(tmp.path), isTrue);
    });
  });
}
