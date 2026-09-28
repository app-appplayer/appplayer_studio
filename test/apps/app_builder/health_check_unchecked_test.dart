/// A health check that did not run must never read as one that found
/// nothing. Covers `healthCheck`, `grade`, and `releaseCheck` when a
/// sub-audit fails or the health reading is missing entirely.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show CanonicalPatch, LayerId, PatchPipelineImpl, WorkspaceCanonicalImpl;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:appplayer_studio/src/apps/app_builder/core/types.dart';
import 'package:appplayer_studio/src/apps/app_builder/core/vibe_project.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';

/// Real dispatcher whose a11y audit can be made to fail, standing in for
/// any sub-audit that errors out at run time.
class _Dispatcher extends BuildToolsDispatcher {
  _Dispatcher({
    required super.project,
    super.canonical,
    super.pipeline,
    super.validator,
    this.failA11y = false,
  });

  final bool failA11y;

  @override
  Future<BuildToolResult> a11yAudit({String? pageId}) async {
    if (failA11y) return BuildToolResult.failure('a11y engine crashed');
    return super.a11yAudit(pageId: pageId);
  }
}

CanonicalPatch _seed() => CanonicalPatch(
  layer: LayerId.appStructure,
  ops: <PatchOp>[
    PatchOp(
      op: 'add',
      path: '/ui/pages',
      value: <String, dynamic>{
        'home': <String, dynamic>{
          'type': 'page',
          'title': 'Home',
          'content': <String, dynamic>{'type': 'text', 'content': 'Hello'},
        },
      },
    ),
    PatchOp(
      op: 'add',
      path: '/ui/routes',
      value: <String, dynamic>{'/home': 'home'},
    ),
    PatchOp(op: 'add', path: '/ui/initialRoute', value: '/home'),
  ],
  originator: const UserOriginator(),
);

Future<_Dispatcher> _open(
  String dir, {
  bool failA11y = false,
  bool withValidator = true,
}) async {
  final canonical = WorkspaceCanonicalImpl(
    fsPort: FileWorkspaceFsPort(),
    validator: SpecValidatorImpl(),
  );
  final bundleDir = p.join(dir, 'bundles', 'serving.mbd');
  await Directory(bundleDir).create(recursive: true);
  await canonical.open(bundleDir);
  await canonical.applyAtomic(_seed());
  final project = VibeProject(
    projectPath: dir,
    canonical: canonical,
    meta: ProjectMeta(
      name: 'test',
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
  // Closed before the test's folder is deleted: the undo sidecar and the
  // draft mirror write after each patch.
  addTearDown(() async {
    await project.dispose();
    await canonical.dispose();
  });
  return _Dispatcher(
    project: project,
    canonical: canonical,
    pipeline: PatchPipelineImpl(
      canonical: canonical,
      validator: SpecValidatorImpl(),
    ),
    validator: withValidator ? SpecValidatorImpl() : null,
    failA11y: failA11y,
  );
}

Map<String, dynamic> _payload(BuildToolResult r) =>
    jsonDecode(r.payload!) as Map<String, dynamic>;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('health_unchecked_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('every check runs → nothing is reported unchecked', () async {
    final d = await _open(tmp.path);
    final r = await d.healthCheck();
    expect(r.success, isTrue);
    final j = _payload(r);
    expect(j['unchecked'], isEmpty);
    expect(j['status'], isNot('incomplete'));
  });

  test('a failed sub-audit makes health incomplete, not pass', () async {
    final d = await _open(tmp.path, failA11y: true);
    final r = await d.healthCheck();
    expect(r.success, isTrue);
    final j = _payload(r);
    expect(j['status'], 'incomplete');
    final unchecked = (j['unchecked'] as List).cast<Map>();
    expect(unchecked.map((u) => u['check']), contains('a11y'));
    expect(unchecked.first['reason'], contains('a11y engine crashed'));
    expect(r.message, contains('unchecked'));
    expect(r.message, isNot(contains('all green')));
  });

  test('grade refuses to score over a check that did not run', () async {
    final d = await _open(tmp.path, failA11y: true);
    final r = await d.grade();
    expect(r.success, isFalse);
    expect(r.message, contains('incomplete'));
    expect(r.message, contains('a11y'));
  });

  test('release is not ready when a check did not run', () async {
    final d = await _open(tmp.path, failA11y: true);
    final r = await d.releaseCheck();
    final j = _payload(r);
    expect(j['ready'], isFalse);
    expect(r.message, contains('incomplete'));
  });

  test('release is not ready when health itself could not run', () async {
    final d = await _open(tmp.path, withValidator: false);
    final r = await d.releaseCheck();
    final j = _payload(r);
    expect(j['ready'], isFalse);
    expect(r.message, contains('not measured'));
  });
}
