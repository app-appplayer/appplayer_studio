/// A refused open must say WHY it was refused here, not just that it was.
///
/// `studio.project.open` routes to whichever package tab is ACTIVE. A caller
/// holding a perfectly good App Builder project therefore lands in the Ops
/// handler simply because Ops was on screen, and the old message —
/// "Not an Ops project (missing project.opsproj marker)" — sent them looking
/// for a fault in the project. The routing was the fault. This pins the part
/// that turns the dead end into a next step: naming the kind the directory
/// actually is.
@TestOn('vm')
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/ops/ops_shell.dart'
    show foreignProjectKindForTest;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('foreign_kind_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String dirWith(String name, {bool asDir = false}) {
    final d = Directory(p.join(tmp.path, 'proj'))..createSync(recursive: true);
    if (asDir) {
      Directory(p.join(d.path, name)).createSync();
    } else {
      File(p.join(d.path, name)).writeAsStringSync('{}');
    }
    return d.path;
  }

  test('an App Builder project is named as one', () {
    expect(foreignProjectKindForTest(dirWith('project.sbproj')), 'App Builder');
  });

  test('a bare bundle directory is recognised', () {
    // The other common shape a caller points at — no project marker, just the
    // bundle. Still worth naming: it tells them to use `mbdPath` instead.
    expect(foreignProjectKindForTest(dirWith('thing.mbd', asDir: true)),
        'bundle');
  });

  test('an unrecognisable directory says nothing rather than guessing', () {
    final d = Directory(p.join(tmp.path, 'empty'))..createSync();
    expect(foreignProjectKindForTest(d.path), isNull);
  });

  test('a missing directory does not throw', () {
    expect(foreignProjectKindForTest(p.join(tmp.path, 'nope')), isNull);
  });
}
