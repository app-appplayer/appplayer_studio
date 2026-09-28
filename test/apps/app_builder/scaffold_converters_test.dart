/// The embedded and self-UI converters write starter scaffolds. They must
/// say so — in the result and through the tool — and stamp the output with
/// a real sha256 of the canonical that produced it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart'
    show BuiltinToolRegistry, PatchPipelineImpl, WorkspaceCanonicalImpl;
import 'package:appplayer_studio/src/apps/app_builder/conv/dart_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/embed_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/self_ui_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/server_bootstrap.dart';
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late WorkspaceCanonicalImpl canonical;

  String expectedHash() =>
      'sha256:${sha256.convert(utf8.encode(jsonEncode(canonical.current.toJson())))}';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scaffold_conv_');
    canonical = WorkspaceCanonicalImpl(
      fsPort: FileWorkspaceFsPort(),
      validator: SpecValidatorImpl(),
    );
    await canonical.open('${tmp.path}/b.mbd');
  });

  tearDown(() async {
    await canonical.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('embed scaffold lists what it did not generate', () async {
    final r = await EmbedConverterImpl().run(
      canonical: canonical.current,
      mode: EmbedMode.withBundle,
      board: 'esp32',
      outDir: '${tmp.path}/embed',
    );
    expect(r.isScaffold, isTrue);
    expect(r.notGenerated, isNotEmpty);
    expect(r.canonicalHash, expectedHash());
    for (final f in r.writtenFiles) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });

  test('self-UI scaffold lists what it did not generate', () async {
    for (final fw in [SelfUiFramework.lvgl, SelfUiFramework.qt]) {
      final r = await SelfUiConverterImpl().run(
        canonical: canonical.current,
        framework: fw,
        outDir: '${tmp.path}/selfui_${fw.name}',
      );
      expect(r.isScaffold, isTrue, reason: fw.name);
      expect(r.canonicalHash, expectedHash());
    }
  });

  test('the convert tools tell the caller the output is a scaffold', () async {
    final host = mk.InProcessKernelServerHost(name: 'ab', version: '0');
    ServerBootstrap(
      server: BuiltinToolRegistry(host),
      canonical: canonical,
      pipeline: PatchPipelineImpl(
        canonical: canonical,
        validator: SpecValidatorImpl(),
      ),
      dartConv: DartConverterImpl(),
      embedConv: EmbedConverterImpl(),
      selfUiConv: SelfUiConverterImpl(),
    ).register();
    for (final call in <(String, Map<String, dynamic>)>[
      (
        'app_builder.convert.embed',
        {'board': 'rp2040', 'mode': 'native', 'outDir': '${tmp.path}/e'},
      ),
      (
        'app_builder.convert.selfui',
        {'framework': 'lvgl', 'outDir': '${tmp.path}/s'},
      ),
    ]) {
      final r = await host.callTool(call.$1, call.$2);
      expect(r.isError, isNot(isTrue), reason: call.$1);
      final body =
          jsonDecode((r.content.first as mk.KernelTextContent).text) as Map;
      expect(body['scaffold'], isTrue, reason: call.$1);
      expect(body['notGenerated'], isNotEmpty, reason: call.$1);
      final def = host.toolDefinitions.firstWhere((d) => d.name == call.$1);
      expect(def.description.toLowerCase(), contains('scaffold'));
    }
  });
}
