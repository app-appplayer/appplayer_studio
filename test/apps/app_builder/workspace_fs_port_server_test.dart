/// [FileWorkspaceFsPort] — cloud server bundle survival across the
/// port's whole-directory atomic swap.
///
/// Two regressions guarded (both found live scaffolding a
/// `ProjectKind.cloudServerApp` project, 2026-07-13):
///  fp1 — unmanaged top-level entries (`tools/` TS sources; also
///        scenarios/, branding/) must survive `writeAtomicJson`'s
///        temp-dir swap instead of being silently deleted.
///  fp2 — enum round-trip: mcp_bundle ≥0.4.7 models `manifest.type:
///        "server"` / `tools[].kind: "ts"` natively; the port round-trip
///        must keep them lossless. (Originally guarded the pre-0.4.7
///        raw-enum overlay interim — kept as a model regression guard.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart';

Future<Directory> _seedServerBundle(Directory tmp) async {
  final mbd = Directory(p.join(tmp.path, 'srv.mbd'));
  await Directory(p.join(mbd.path, 'ui', 'pages')).create(recursive: true);
  await Directory(p.join(mbd.path, 'tools')).create(recursive: true);
  await File(p.join(mbd.path, 'manifest.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'manifest': <String, dynamic>{
        'id': 'com.example.srv',
        'name': 'Srv',
        'version': '0.1.0',
        'type': 'server',
      },
      'tools': <String, dynamic>{
        'tools': <dynamic>[
          <String, dynamic>{
            'name': 'server.ping',
            'description': 'ping',
            'inputSchema': <String, dynamic>{'type': 'object'},
            'kind': 'ts',
            'target': <String, dynamic>{
              'entry': 'tools/main.ts',
              'fn': 'ping',
            },
          },
        ],
      },
      'ui': <String, dynamic>{'kind': 'mcp_ui_dsl', 'path': 'ui/app.json'},
    }),
  );
  await File(p.join(mbd.path, 'ui', 'app.json')).writeAsString(
    jsonEncode(<String, dynamic>{
      'type': 'application',
      'title': 'Srv',
      'initialRoute': '/home',
      'routes': <String, dynamic>{'/home': 'ui://pages/home'},
    }),
  );
  await File(p.join(mbd.path, 'ui', 'pages', 'home.json')).writeAsString(
    jsonEncode(<String, dynamic>{'type': 'page', 'title': 'Home'}),
  );
  await File(p.join(mbd.path, 'tools', 'main.ts')).writeAsString(
    'export async function ping(a: Record<string, unknown>) '
    '{ return { ok: true }; }\n',
  );
  await File(p.join(mbd.path, 'tools', 'package.json'))
      .writeAsString('{"name":"srv-tools","private":true}\n');
  return mbd;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vibe_fs_port_srv_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('fp1: writeAtomicJson round-trip preserves unmanaged tools/ entries',
      () async {
    final mbd = await _seedServerBundle(tmp);
    final port = FileWorkspaceFsPort();

    final json = await port.readJson(mbd.path);
    expect(json, isNotNull);
    await port.writeAtomicJson(json!, mbd.path);

    expect(File(p.join(mbd.path, 'tools', 'main.ts')).existsSync(), isTrue,
        reason: 'tools/main.ts must survive the atomic swap');
    expect(
      File(p.join(mbd.path, 'tools', 'package.json')).existsSync(),
      isTrue,
      reason: 'tools/package.json must survive the atomic swap',
    );
  });

  test('fp2: server/ts enum values survive read → write round-trip',
      () async {
    final mbd = await _seedServerBundle(tmp);
    final port = FileWorkspaceFsPort();

    final json = await port.readJson(mbd.path);
    expect(json, isNotNull);
    // Read overlay: the in-memory view carries the raw values.
    expect((json!['manifest'] as Map)['type'], 'server');
    expect(
      ((json['tools'] as Map)['tools'] as List).first['kind'],
      'ts',
    );

    await port.writeAtomicJson(json, mbd.path);

    // Write restore: the re-written manifest.json still carries them.
    final written = jsonDecode(
      await File(p.join(mbd.path, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect((written['manifest'] as Map)['type'], 'server');
    expect(
      ((written['tools'] as Map)['tools'] as List).first['kind'],
      'ts',
    );
    // target {entry, fn} is model-preserved — assert to catch regressions.
    expect(
      ((written['tools'] as Map)['tools'] as List).first['target'],
      <String, dynamic>{'entry': 'tools/main.ts', 'fn': 'ping'},
    );
  });

  test('fp1b: model-owned entries still win — a deleted page stays deleted',
      () async {
    final mbd = await _seedServerBundle(tmp);
    final port = FileWorkspaceFsPort();

    final json = await port.readJson(mbd.path);
    // Remove the only page from the in-memory ui tree and save.
    final ui = json!['ui'] as Map<String, dynamic>;
    (ui['pages'] as Map?)?.remove('home');
    await port.writeAtomicJson(json, mbd.path);

    expect(
      File(p.join(mbd.path, 'ui', 'pages', 'home.json')).existsSync(),
      isFalse,
      reason: 'ui/ is model-owned — the preserve step must not resurrect '
          'deleted pages',
    );
    // Unmanaged tools/ still intact.
    expect(File(p.join(mbd.path, 'tools', 'main.ts')).existsSync(), isTrue);
  });
}
