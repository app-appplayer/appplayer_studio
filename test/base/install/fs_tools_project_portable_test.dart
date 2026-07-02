/// `registerFsTools` project-portability — a **project-relative** `path`
/// resolves against the ACTIVE project root (`activeProjectRoot`), so the same
/// stored relative link follows the project folder when it is renamed / moved.
/// The workspaceDir jail is preserved: paths escaping both the active project
/// and the workspaceDir are rejected.
///
/// This is the host-level seam every built-in (Ops / Scene Builder / App
/// Builder) and future bundle app inherits for portable file references.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/install/fs_tools.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> _json(mk.KernelToolResult r) =>
    jsonDecode(r.content.whereType<mk.KernelTextContent>().first.text)
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory a; // original project root
  late Directory b; // moved / renamed project root
  late mk.InProcessKernelServerHost boot;
  String? activeRoot;

  setUp(() async {
    a = await Directory.systemTemp.createTemp('fs_portable_a_');
    b = await Directory.systemTemp.createTemp('fs_portable_b_');
    boot = mk.InProcessKernelServerHost();
    registerFsTools(
      boot,
      toolId: 'fs_portable_test',
      activeProjectRoot: () => activeRoot,
    );
    activeRoot = a.path;
  });

  tearDown(() async {
    if (a.existsSync()) await a.delete(recursive: true);
    if (b.existsSync()) await b.delete(recursive: true);
  });

  test('project-relative write+read resolves against the active project root',
      () async {
    final w = await boot.callTool('studio.fs.write', <String, dynamic>{
      'path': 'knowledge/note.md',
      'content': 'hello',
    });
    expect(_json(w)['ok'], isTrue);
    expect(File(p.join(a.path, 'knowledge', 'note.md')).existsSync(), isTrue);

    final r = await boot.callTool('studio.fs.read', <String, dynamic>{
      'path': 'knowledge/note.md',
    });
    expect(_json(r)['content'], 'hello');
  });

  test('same relative link follows the project after a move (portable)',
      () async {
    // Author the link under project A.
    await boot.callTool('studio.fs.write', <String, dynamic>{
      'path': 'knowledge/note.md',
      'content': 'from-A',
    });
    // Simulate a rename / move: the content now lives under B and the active
    // project root repoints. The SAME stored relative path must resolve there.
    await Directory(p.join(b.path, 'knowledge')).create(recursive: true);
    await File(p.join(b.path, 'knowledge', 'note.md')).writeAsString('from-B');
    activeRoot = b.path;

    final r = await boot.callTool('studio.fs.read', <String, dynamic>{
      'path': 'knowledge/note.md',
    });
    expect(_json(r)['content'], 'from-B'); // resolved against B, not stale A
  });

  test('absolute path escaping both boundaries is rejected (jail preserved)',
      () async {
    final r = await boot.callTool('studio.fs.read', <String, dynamic>{
      'path': '/etc/passwd',
    });
    expect(r.isError, isTrue);
  });

  test('.. traversal escaping the project root is rejected', () async {
    final r = await boot.callTool('studio.fs.read', <String, dynamic>{
      'path': '../../../../../../etc/passwd',
    });
    expect(r.isError, isTrue);
  });

  test('no active project and no workspaceDir → clear error, not a crash',
      () async {
    activeRoot = null;
    final r = await boot.callTool('studio.fs.read', <String, dynamic>{
      'path': 'knowledge/note.md',
    });
    expect(r.isError, isTrue);
    expect(_json(r)['error'].toString(), contains('no workspaceDir'));
  });
}
