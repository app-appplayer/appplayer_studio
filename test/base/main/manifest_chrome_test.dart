/// Manifest → chrome readers (lifecycle state bindings, title / status bar
/// text, slash chips) shared by every host that runs a bundle as an app.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('manifest_chrome_');
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'a.b', 'name': 'A', 'version': '1'},
        'wiring': <String, dynamic>{
          'lifecycleStateBindings': <String, dynamic>{
            'projectName': '{{currentProject}}',
            'hasProject': "{{currentProject != ''}}",
            'dirty': '{{isDirty}}',
            'canUndo': '{{!locked}}',
            'canRedo': false,
          },
        },
        'chat': <String, dynamic>{
          'slashCommands': <Map<String, dynamic>>[
            <String, dynamic>{
              'command': '/run',
              'description': 'Run it',
              'tool': 'run',
              'arguments': <String, dynamic>{'fast': true},
            },
            <String, dynamic>{'description': 'no command — skipped'},
          ],
        },
      }),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('lifecycle bindings resolve against runtime state', () {
    final life =
        readManifestLifecycleBindings(dir.path, <String, Object?>{
          'currentProject': '/docs/a.txt',
          'isDirty': true,
          'locked': false,
        })!;
    expect(life.projectName, '/docs/a.txt');
    expect(life.hasProject, isTrue);
    expect(life.dirty, isTrue);
    expect(life.canUndo, isTrue);
    expect(life.canRedo, isFalse);

    final empty = readManifestLifecycleBindings(dir.path, const {})!;
    expect(empty.hasProject, isFalse);
    expect(empty.dirty, isFalse);
  });

  test('no bindings → null', () {
    final other = Directory(p.join(dir.path, 'x'))..createSync();
    File(p.join(other.path, 'manifest.json')).writeAsStringSync('{}');
    expect(readManifestLifecycleBindings(other.path, const {}), isNull);
    expect(readManifestLifecycleBindings('', const {}), isNull);
  });

  test('binding expressions', () {
    const state = <String, Object?>{'a': '', 'b': 'x', 'n': 0};
    expect(evalChromeBinding("{{a == ''}}", state), isTrue);
    expect(evalChromeBinding("{{b != ''}}", state), isTrue);
    expect(evalChromeBinding('{{!n}}', state), isTrue);
    expect(evalChromeBinding('{{b}}', state), 'x');
    expect(evalChromeBinding('plain', state), 'plain');
  });

  test('chrome text interpolation walks nested paths', () {
    expect(
      interpolateChromeText('{{doc.name}} · {{count}} · {{none}}', {
        'doc': {'name': 'a.txt'},
        'count': 3,
      }),
      'a.txt · 3 · ',
    );
  });

  test('slash chips keep tool and arguments, skip entries without command', () {
    final hints = readManifestSlashHints(dir.path);
    expect(hints, hasLength(1));
    expect(hints.single.command, '/run');
    expect(hints.single.tool, 'run');
    expect(hints.single.arguments, <String, dynamic>{'fast': true});
  });
}
