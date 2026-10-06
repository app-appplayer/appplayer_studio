/// The Studio Package a new App Builder project starts from is a Studio
/// app (`type: extension`) whose declared tools all register and run.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart'
    show ProjectKind;
import 'package:appplayer_studio/src/apps/app_builder/infra/project_seed.dart'
    show applyProjectSeed;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the seed is a clean extension whose tools all register', () async {
    final tmp = Directory.systemTemp.createTempSync('studio_pkg_seed_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dir = p.join(tmp.path, 'demo.mbd');
    await applyProjectSeed(dir, ProjectKind.studioPackage, 'demo');

    final manifest =
        jsonDecode(File(p.join(dir, 'manifest.json')).readAsStringSync())
            as Map<String, dynamic>;
    expect((manifest['manifest'] as Map)['type'], 'extension');
    expect(selfNamedToolReferences(dir), isEmpty);

    final bundle = readBundleAt(dir)!;
    final boot = mk.InProcessKernelServerHost();
    final ctx = HostBundleActivationContext(
      boot: boot,
      tabKey: dir,
      bundle: bundle,
      exposedShortId: bundle.shortId,
    );
    addTearDown(ctx.unregisterAll);
    for (final tool in bundle.tools!.tools) {
      final r = await ctx.registerTool(tool);
      expect(r.ok, isTrue, reason: '${tool.name}: ${r.error}');
    }
    final result = await boot.callTool('demo.hello', const {'name': 'Ada'});
    expect(result.isError, isFalse);
    expect(
      (result.content.single as mk.KernelTextContent).text,
      contains('Hello, Ada'),
    );
  });

  test('a re-declared host builtin is a declaration, not a failure', () async {
    // Bundle spec 04 §4.4 — `kind: host` names a tool the host already
    // dispatches; the bundle may list it for documentation.
    final tmp = Directory.systemTemp.createTempSync('host_kind_decl_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dir = p.join(tmp.path, 'decl.mbd');
    Directory(dir).createSync();
    File(p.join(dir, 'manifest.json')).writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'manifest': <String, dynamic>{'id': 'com.acme.decl', 'version': '1'},
        'tools': <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'studio.fs.read', 'kind': 'host'},
          ],
        },
      }),
    );
    final bundle = readBundleAt(dir)!;
    final boot = mk.InProcessKernelServerHost();
    final ctx = HostBundleActivationContext(
      boot: boot,
      tabKey: dir,
      bundle: bundle,
      exposedShortId: bundle.shortId,
    );
    addTearDown(ctx.unregisterAll);
    final r = await ctx.registerTool(bundle.tools!.tools.single);
    expect(r.ok, isTrue, reason: r.error);
    expect(r.exposedName, isEmpty);
    expect(boot.toolScopes.keys.where((k) => k.startsWith('decl.')), isEmpty);
  });
}
