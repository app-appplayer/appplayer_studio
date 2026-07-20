/// [prepareServerShellLaunch] + discovery helpers — the Cloud Server
/// debug variant's launch preparation (pack → tsc → spawn description).
/// Node/npx-dependent paths are exercised only up to their precondition
/// errors so the suite stays hermetic.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/widgets/server_shell_launch.dart';

Future<String> _makeProject(
  Directory tmp, {
  String type = 'server',
  bool withTsTool = false,
}) async {
  final proj = Directory(p.join(tmp.path, 'proj'));
  final mbd = Directory(p.join(proj.path, 'bundles', 'proj.mbd'));
  await Directory(p.join(mbd.path, 'ui')).create(recursive: true);
  await File(p.join(proj.path, 'project.apbproj')).writeAsString(
    jsonEncode(<String, dynamic>{
      'name': 'proj',
      'activeChannel': 'serving',
      'channels': <String, dynamic>{
        'serving': <String, dynamic>{'subdir': 'bundles/proj.mbd'},
      },
    }),
  );
  await File(p.join(mbd.path, 'manifest.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'manifest': <String, dynamic>{
        'id': 'com.example.proj',
        'name': 'proj',
        'version': '0.1.0',
        'type': type,
      },
    }),
  );
  await File(p.join(mbd.path, 'ui', 'app.json')).writeAsString(
    jsonEncode(<String, dynamic>{'type': 'application', 'title': 'proj'}),
  );
  if (withTsTool) {
    await Directory(p.join(mbd.path, 'tools')).create(recursive: true);
    await File(p.join(mbd.path, 'tools', 'main.ts'))
        .writeAsString('export async function ping() { return {}; }\n');
  }
  return proj.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vibe_srv_launch_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('sl1: servingBundleDirOf resolves the active channel subdir',
      () async {
    final proj = await _makeProject(tmp);
    expect(servingBundleDirOf(proj), p.join(proj, 'bundles', 'proj.mbd'));
    expect(servingBundleDirOf(p.join(tmp.path, 'nope')), isNull);
  });

  test('sl1b: projectKindNameOf reads the apbproj kind', () async {
    final proj = await _makeProject(tmp);
    // _makeProject writes no kind field -> null (fallback = app default).
    expect(projectKindNameOf(proj), isNull);
    final metaFile = File(p.join(proj, 'project.apbproj'));
    final meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    meta['kind'] = 'cloudServerApp';
    await metaFile.writeAsString(jsonEncode(meta));
    expect(projectKindNameOf(proj), 'cloudServerApp');
  });

  test('sl2: isServerBundleDir keys on manifest.type', () async {
    final srv = await _makeProject(tmp);
    expect(isServerBundleDir(servingBundleDirOf(srv)!), isTrue);
    await tmp.list().forEach((e) => e.deleteSync(recursive: true));
    final app = await _makeProject(tmp, type: 'application');
    expect(isServerBundleDir(servingBundleDirOf(app)!), isFalse);
  });

  test('sl3: non-server bundle → actionable error, no artifacts', () async {
    final proj = await _makeProject(tmp, type: 'application');
    expect(
      () => prepareServerShellLaunch(
        projectPath: proj,
        serverShellPath: '/nonexistent',
      ),
      throwsA(
        isA<ServerShellLaunchException>().having(
          (e) => e.message,
          'message',
          contains('not a cloud server app'),
        ),
      ),
    );
  });

  test('sl4: missing serverShellPath → settings hint', () async {
    final proj = await _makeProject(tmp);
    expect(
      () => prepareServerShellLaunch(projectPath: proj, serverShellPath: null),
      throwsA(
        isA<ServerShellLaunchException>().having(
          (e) => e.message,
          'message',
          contains('serverShellPath'),
        ),
      ),
    );
  });

  test('sl5: unbuilt shell (no lib/index.js) → build hint', () async {
    final proj = await _makeProject(tmp);
    final shell = Directory(p.join(tmp.path, 'shell'))..createSync();
    expect(
      () => prepareServerShellLaunch(
        projectPath: proj,
        serverShellPath: shell.path,
      ),
      throwsA(
        isA<ServerShellLaunchException>().having(
          (e) => e.message,
          'message',
          contains('npm run build'),
        ),
      ),
    );
  });

  test(
      'sl6: tool-less server bundle packs to build/server/<name>.mcpb '
      'and describes the spawn (no npx needed)', () async {
    final proj = await _makeProject(tmp); // no ts tools → tsc skipped
    final shell = Directory(p.join(tmp.path, 'shell', 'lib'))
      ..createSync(recursive: true);
    await File(p.join(shell.path, 'index.js')).writeAsString('// stub\n');

    final launch = await prepareServerShellLaunch(
      projectPath: proj,
      serverShellPath: p.join(tmp.path, 'shell'),
    );
    expect(File(launch.mcpbPath).existsSync(), isTrue);
    expect(launch.mcpbPath, contains(p.join('build', 'server')));
    expect(launch.indexJs, endsWith(p.join('lib', 'index.js')));
    expect(launch.environment['BUNDLE_PATH'], launch.mcpbPath);
    expect(launch.environment['SERVER_AUTH_MODE'], 'open');
    // Port is scanned upward from the base (free-port allocation).
    final port = int.parse(launch.environment['PORT']!);
    expect(port, greaterThanOrEqualTo(kServerShellDebugPort));
    expect(launch.port, port);
    expect(launch.environment.containsKey('TOOLS_DIR'), isFalse);
  });

  test('sl7: packed mcpb excludes authoring metadata (.history, dot-files)',
      () async {
    final proj = await _makeProject(tmp);
    final mbd = servingBundleDirOf(proj)!;
    // Simulate authoring residue: a stale page snapshot + OS junk.
    final hist = Directory(
      p.join(mbd, '.history', '2026-01-01T00-00-00-edit', 'ui', 'pages'),
    )..createSync(recursive: true);
    File(p.join(hist.path, 'home.json')).writeAsStringSync('{"stale":true}');
    File(p.join(mbd, '.DS_Store')).writeAsStringSync('junk');

    final shell = Directory(p.join(tmp.path, 'shell', 'lib'))
      ..createSync(recursive: true);
    await File(p.join(shell.path, 'index.js')).writeAsString('// stub\n');

    final launch = await prepareServerShellLaunch(
      projectPath: proj,
      serverShellPath: p.join(tmp.path, 'shell'),
    );
    final bytes = await File(launch.mcpbPath).readAsBytes();
    // Decode entry names without a zip dep: names appear in the central
    // directory as raw strings.
    final blob = String.fromCharCodes(bytes);
    expect(blob.contains('.history'), isFalse,
        reason: '.history snapshots must not ship — loose-matching '
            'consumers can serve the stale page over the live one');
    expect(blob.contains('.DS_Store'), isFalse);
    expect(blob.contains('ui/app.json'), isTrue,
        reason: 'real content must still be packed');
  });
}
