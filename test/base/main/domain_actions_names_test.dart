/// Domain action tool names resolve the way every bundle-internal name
/// does: the bundle's own namespace first, then as written (platform spec
/// 04-ui-host "Name isolation").
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('domain_actions_names_');
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'a.kanban', 'version': '1'},
        'wiring': <String, dynamic>{
          'domainActions': <Map<String, dynamic>>[
            <String, dynamic>{'tool': 'save'},
            <String, dynamic>{'tool': 'board.summary'},
            <String, dynamic>{'tool': 'kanban.save'},
            <String, dynamic>{'tool': 'studio.fs.read'},
          ],
        },
      }),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('declared, dotted-declared, full and host names all reach', () async {
    const registered = <String>{
      'kanban.save',
      'kanban.board.summary',
      'studio.fs.read',
    };
    final called = <String>[];
    final actions = readDomainActionsFromManifest(
      mbdPath: dir.path,
      invokeTool: (name, _) async => called.add(name),
      isRegistered: registered.contains,
      exposedNs: 'kanban',
    );
    for (final a in actions) {
      a.onTap!();
    }
    await Future<void>.delayed(Duration.zero);
    expect(called, <String>[
      'kanban.save',
      'kanban.board.summary',
      'kanban.save',
      'studio.fs.read',
    ]);
  });
}
