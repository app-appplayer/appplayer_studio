// Concurrent settings writers must not lose each other's edits.
//
// Built-ins record their last project into the one host settings file from
// their own async paths. Two overlapping load → edit → save sequences left
// the file with only the later writer's key (Form Builder's last project
// vanished after a restart, R13 2026-09-05). `mutate` chains the edits per
// path so every key survives.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/settings/vibe_settings.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vibe_settings_mutate_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('overlapping mutations keep every key', () async {
    final path = p.join(tmp.path, 'settings.json');
    await Future.wait(<Future<void>>[
      VibeSettings.mutate(path, (s) => s.domainLastProject['ops'] = '/a'),
      VibeSettings.mutate(path, (s) => s.domainLastProject['form'] = '/b'),
      VibeSettings.mutate(path, (s) => s.bumpRecent('/c')),
    ]);
    final s = await VibeSettings.load(path);
    expect(s.domainLastProject, {'ops': '/a', 'form': '/b'});
    expect(s.recentProjects, contains('/c'));
  });

  test('a failing edit does not block the next mutation', () async {
    final path = p.join(tmp.path, 'settings.json');
    await expectLater(
      VibeSettings.mutate(path, (_) => throw StateError('boom')),
      throwsStateError,
    );
    await VibeSettings.mutate(path, (s) => s.domainLastProject['x'] = '/x');
    expect((await VibeSettings.load(path)).domainLastProject, {'x': '/x'});
  });

  test('unrelated load → save pairs still race (documents the reason)', () async {
    final path = p.join(tmp.path, 'settings.json');
    final a = await VibeSettings.load(path);
    final b = await VibeSettings.load(path);
    a.domainLastProject['ops'] = '/a';
    b.domainLastProject['form'] = '/b';
    await a.save(path);
    await b.save(path);
    // The plain path loses the first writer; that is what mutate is for.
    expect((await VibeSettings.load(path)).domainLastProject, {'form': '/b'});
  });
}
