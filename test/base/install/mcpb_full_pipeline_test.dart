import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:brain_kernel/mcp_host.dart' as mh;

/// Full default-tool-package pipeline:
///
///   1. Source `.mbd/` exists on disk (`example/wire_demo.mbd`)
///   2. `McpbPackager.pack` → produces `.mcpb` (zip)
///   3. `BundleInstallSurface.install(<mcpb>)` → extracts +
///      registers, returns the registered `mbdPath`
///   4. `readBundleAt(<mbdPath>)` parses the canonical bundle
///   5. `HostBundleActivationContext` registers tools
///   6. `boot.callTool` invokes the JS tool, returns the
///      shouted text
///
/// If this passes, vibe_studio has every capability needed to ship
/// the four default tool packages (AppPlayer Pro · app_builder ·
/// knowledge_builder · Ops): hand-author the `.mbd`, pack to
/// `.mcpb`, install, activate, dispatch.
///
/// This is the answer to "can that capability be built in the current
/// studio today" — yes, end-to-end.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mcpb full pipeline (.mbd → .mcpb → install → activate → call)', () {
    test('pack + install + activate + call wire_demo.mbd', () async {
      // Source .mbd lives next to the package — the canonical sample
      // we author by hand.
      final sourceMbd = p.normalize(
        p.join(Directory.current.path, 'example', 'wire_demo.mbd'),
      );
      expect(
        Directory(sourceMbd).existsSync(),
        isTrue,
        reason: 'sample wire_demo.mbd missing',
      );

      // Workspace for the pack output + install cache. Auto-cleaned.
      final workspace = Directory.systemTemp.createTempSync('vibe_pipeline_');
      addTearDown(() {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      });

      final mcpbPath = p.join(workspace.path, 'wire_demo.mcpb');
      final installCache = Directory(p.join(workspace.path, 'installed'))
        ..createSync();

      // 1. Pack — wire_demo.mbd → wire_demo.mcpb (zip).
      final packed = await mk.McpbPackager.pack(sourceMbd, mcpbPath);
      expect(File(packed).existsSync(), isTrue);
      expect(File(packed).lengthSync(), greaterThan(0));

      // 2. Install — feed the .mcpb through the install surface,
      //    same code path the studio.bundle.install MCP tool uses.
      final boot = mk.InProcessKernelServerHost();
      // The install surface needs a knowledge engine reference; for
      // the pipeline test we never query knowledge so a minimal
      // engine pointed at an empty registry is enough.
      final registry = mk.KnowledgeBundleRegistry(
        storageDir: p.join(workspace.path, 'kbr'),
      );
      final knowledgeEngine = mk.KnowledgeQueryEngine(registry: registry);
      final installer = BundleInstallSurface(
        bundleRegistry: registry,
        knowledgeEngine: knowledgeEngine,
        installedCacheDir: installCache.path,
      );
      final installResult = await installer.install(packed);
      expect(
        installResult['ok'],
        isTrue,
        reason: installResult['error']?.toString() ?? '',
      );
      final installedMbd = installResult['mbdPath'] as String;
      expect(Directory(installedMbd).existsSync(), isTrue);

      // 3. Read the installed manifest as the canonical McpBundle.
      final bundle = readBundleAt(installedMbd)!;
      expect(bundle.bundleId, 'com.makemind.examples.wire_demo');
      expect(bundle.tools!.tools.single.name, 'shout');

      // 4. Activate.
      final ctx = HostBundleActivationContext(
        boot: boot,
        tabKey: installedMbd,
        bundle: bundle,
        exposedShortId: bundle.shortId,
      );
      addTearDown(ctx.unregisterAll);
      expect(ctx.validateBuiltinTools(), isTrue);
      final reg = await ctx.registerTool(bundle.tools!.tools.single);
      expect(reg.ok, isTrue, reason: reg.error ?? '');
      expect(reg.exposedName, 'wire_demo.shout');

      // 5. Dispatch — full round trip from the host MCP server.
      final result = await boot.callTool('wire_demo.shout', const {
        'text': 'pipeline',
      });
      expect(result.isError, isFalse);
      final body = (result.content.single as mk.KernelTextContent).text;
      expect(jsonDecode(body), {'shouted': 'PIPELINE'});
    });
  });
}
