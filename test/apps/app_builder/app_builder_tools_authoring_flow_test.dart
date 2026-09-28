/// App Builder authoring driven the way an external LLM drives it: only
/// `app_builder.*` tool calls through the host registry, over a real
/// canonical bundle, build dispatcher and bridge. Each step reads back what
/// the previous one wrote.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart'
    show BuiltinToolRegistry, PatchPipelineImpl, WorkspaceCanonicalImpl;
import 'package:appplayer_studio/src/apps/app_builder/conv/dart_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/embed_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/self_ui_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/server_bootstrap.dart';
import 'package:appplayer_studio/src/apps/app_builder/infra/vibe_server_bridge.dart';
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late mk.InProcessKernelServerHost host;
  late WorkspaceCanonicalImpl canonical;
  late VibeProject project;

  Future<({bool error, Map<String, dynamic> body})> call(
    String name,
    Map<String, dynamic> args,
  ) async {
    final r = await host.callTool(name, args);
    final text =
        r.content.whereType<mk.KernelTextContent>().map((c) => c.text).join();
    return (
      error: r.isError == true,
      body: jsonDecode(text) as Map<String, dynamic>,
    );
  }

  /// Build tools wrap their result as `{ok, message, payload: "<json>"}`.
  Future<Map<String, dynamic>> build(
    String verb,
    Map<String, dynamic> args,
  ) async {
    final r = await call('app_builder.build.$verb', args);
    expect(r.error, isFalse, reason: '$verb: ${r.body}');
    expect(r.body['ok'], isTrue, reason: '$verb: ${r.body}');
    final payload = r.body['payload'];
    return payload is String
        ? jsonDecode(payload) as Map<String, dynamic>
        : <String, dynamic>{};
  }

  Future<Object?> read(String pointer) async {
    final r = await call('app_builder.read', {'pointer': pointer});
    expect(r.error, isFalse, reason: 'read $pointer: ${r.body}');
    return r.body['value'];
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ab_flow_');
    canonical = WorkspaceCanonicalImpl(
      fsPort: FileWorkspaceFsPort(),
      validator: SpecValidatorImpl(),
    );
    final bundle = '${tmp.path}/bundles/serving.mbd';
    await Directory(bundle).create(recursive: true);
    await canonical.open(bundle);
    final pipeline = PatchPipelineImpl(
      canonical: canonical,
      validator: SpecValidatorImpl(),
    );
    project = VibeProject(
      projectPath: tmp.path,
      canonical: canonical,
      meta: ProjectMeta(
        name: 'flow',
        createdAt: DateTime(2024),
        lastOpenedAt: DateTime(2024),
        channels: <String, ChannelDef>{
          'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
        },
        activeChannel: 'serving',
      ),
      chatLog: null,
      historyLog: null,
      undoSidecar: null,
    );
    final dispatcher = BuildToolsDispatcher(
      project: project,
      canonical: canonical,
      pipeline: pipeline,
      validator: SpecValidatorImpl(),
    );
    final bridge =
        VibeServerBridge()
          ..getBuildTools = (() => dispatcher)
          ..getProject = (() => project);
    host = mk.InProcessKernelServerHost(name: 'ab', version: '0');
    ServerBootstrap(
      server: BuiltinToolRegistry(host),
      canonical: canonical,
      pipeline: pipeline,
      dartConv: DartConverterImpl(),
      embedConv: EmbedConverterImpl(),
      selfUiConv: SelfUiConverterImpl(),
      bridge: bridge,
    ).register();
  });

  tearDown(() async {
    // Close the project and canonical first: the undo sidecar and the draft
    // mirror write after each patch, and deleting the folder under a
    // pending write fails the delete.
    await project.dispose();
    await canonical.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test(
    'create a page, add, edit and remove a widget, rename the page',
    () async {
      await build('page_create', {'id': 'home'});
      await build('add_child', {
        'parentPath': '/ui/pages/home/content',
        'widget': {'type': 'text', 'content': 'Hello'},
      });
      expect(await read('/ui/pages/home/content/children/0'), {
        'type': 'text',
        'content': 'Hello',
      });

      await build('set_property', {
        'path': '/ui/pages/home/content/children/0',
        'key': 'content',
        'value': 'Hi there',
      });
      final widget = await build('get_widget', {
        'path': '/ui/pages/home/content/children/0',
      });
      expect((widget['widget'] as Map)['content'], 'Hi there');

      await build('rename_page', {'oldId': 'home', 'newId': 'start'});
      expect(await read('/ui/pages/home'), isNull);
      expect(await read('/ui/pages/start/content/children/0'), isNotNull);

      await build('delete_widget', {
        'path': '/ui/pages/start/content/children/0',
      });
      expect(await read('/ui/pages/start/content/children'), isEmpty);
    },
  );

  test('scaffold converters write under the project root', () async {
    // Project-relative outDir, as the manual shows (`outDir=build/embed`) —
    // anchored to the project, like convert.dart, not to the process cwd.
    for (final c in <(String, Map<String, dynamic>, String)>[
      (
        'app_builder.convert.embed',
        {'board': 'rp2040', 'mode': 'native', 'outDir': 'build/embed'},
        'build/embed/CMakeLists.txt',
      ),
      (
        'app_builder.convert.selfui',
        {'framework': 'lvgl', 'outDir': 'build/selfui'},
        'build/selfui/src/ui_main.c',
      ),
    ]) {
      final r = await call(c.$1, c.$2);
      expect(r.error, isFalse, reason: '${c.$1}: ${r.body}');
      expect(File('${tmp.path}/${c.$3}').existsSync(), isTrue);
    }
    final outside = await call('app_builder.convert.embed', {
      'board': 'rp2040',
      'mode': 'native',
      'outDir': '${Directory.systemTemp.path}/outside_project_embed',
    });
    expect(outside.error, isTrue);
    expect(
      Directory(
        '${Directory.systemTemp.path}/outside_project_embed',
      ).existsSync(),
      isFalse,
    );
  });

  test('layout presets write line height under its canonical name', () async {
    // UI DSL 1.4 TextStyle: `lineHeight` is canonical, `height` is the old
    // name — read, never emitted.
    const kinds = <String>[
      'hero',
      'cardList',
      'form',
      'settings',
      'gallery',
      'magazine',
      'carousel',
      'playlist',
      'landing',
    ];
    final offenders = <String>[];
    void walk(Object? node, String path) {
      if (node is Map) {
        final style = node['style'];
        if (style is Map && style.containsKey('height')) offenders.add(path);
        node.forEach((k, v) => walk(v, '$path/$k'));
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$path/$i');
        }
      }
    }

    for (final kind in kinds) {
      await build('page_create', {'id': 'p_$kind'});
      await build('apply_layout_preset', {'pageId': 'p_$kind', 'kind': kind});
      walk(await read('/ui/pages/p_$kind'), kind);
    }
    expect(offenders, isEmpty);
  });

  test('outline reflects each authoring step', () async {
    await build('page_create', {'id': 'home'});
    final before = await build('tree_outline', {});
    await build('add_child', {
      'parentPath': '/ui/pages/home/content',
      'widget': {'type': 'text', 'content': 'x'},
    });
    final after = await build('tree_outline', {});
    expect(
      (after['widgets'] as List).length,
      (before['widgets'] as List).length + 1,
    );
  });

  test('health check runs every sub-check and reports real findings', () async {
    await build('page_create', {'id': 'home'});
    final health = await build('health_check', {});
    expect(health['unchecked'], isEmpty);
    expect(health['status'], isIn(<String>['pass', 'warn', 'fail']));
  });

  test('failures reach the caller as errors', () async {
    final missing = await call('app_builder.build.get_widget', {
      'path': '/ui/pages/nope',
    });
    expect(missing.error, isTrue);
    expect(missing.body['message'], contains('not found'));

    final badTarget = await call('app_builder.build.find_references', {
      'target': 'start',
    });
    expect(badTarget.error, isTrue);
  });
}
