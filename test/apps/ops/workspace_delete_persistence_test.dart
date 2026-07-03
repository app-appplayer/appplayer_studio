/// `workspace_delete` must be PERSISTENT — integration regression over a real
/// `KnowledgeInit.boot`.
///
/// Reproduces the reported bug (konpi, user-witnessed): deleting `org/bookclub`
/// returned `{deleted:true}` and dropped it from `workspace_list`, yet the
/// workspace's members stayed resolvable and the Ops tab resurrected it on the
/// next boot. Cause: a workspace has TWO on-disk homes and `delete` removed
/// only one —
///   1. metadata dir `<root>/<id>` (the type-nested `config.yaml` that
///      `workspace_list` scans), and
///   2. content bundle `<root>/<slug>.mbd` (members / skills / processes read
///      directly by `member_list({workspaceId})` + the tab).
/// The leaked (2) is the resurrection source. `delete` now removes both.
///
///   wd1  before delete, both the metadata dir and the `.mbd` content bundle
///        exist and the member is listed.
///   wd2  after delete, both dirs are gone, `member_list` is empty, and the
///        workspace does not resurrect on a registry reload.
library;

import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart' show ModelSpec;
import 'package:appplayer_studio/src/apps/ops/config/ops_config.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart'
    show wsContentRoot;
import 'package:appplayer_studio/src/apps/ops/init/knowledge_init.dart';
import 'package:appplayer_studio/src/apps/ops/registries/workspace_registry.dart';
import 'package:flutter_test/flutter_test.dart';

OpsConfig _bound(String root) => OpsConfig(
  version: 'test',
  appName: 'test',
  activeWorkspace: '_system',
  workspacesRoot: root,
  llm: const LlmSettings.empty(),
  mcp: const McpSettings.defaults(),
  browser: const BrowserSettings.defaults(),
  storage: StorageSettings(localKvPath: '$root/.kv'),
  channel: const ChannelSettings.empty(),
  security: const SecuritySettings.defaults(),
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ws_delete_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  test('workspace_delete removes BOTH the metadata dir and the .mbd content — '
      'no resurrection', () async {
    final init = await KnowledgeInit.boot(_bound(tmp.path));
    final ws = init.registries.workspace;
    await ws.create(type: WorkspaceType.org, slug: 'temp', title: 'Temp');
    // A member materialises the `.mbd` content bundle (`<slug>.mbd/members/`).
    await init.registries.member.createAgent(
      id: 'temp_lead',
      displayName: 'Tess',
      profileRef: '',
      skillIds: const [],
      philosophyRef: '',
      workspaceId: 'org/temp',
      model: const ModelSpec(provider: 'stub', model: 'stub-1'),
    );

    final metaDir = Directory('${tmp.path}/org/temp');
    final contentDir = Directory(wsContentRoot(tmp.path, 'org/temp'));

    // wd1 — both homes exist + the member is listed.
    expect(metaDir.existsSync(), isTrue, reason: 'metadata dir should exist');
    expect(contentDir.existsSync(), isTrue, reason: '.mbd bundle should exist');
    expect(
      (await init.registries.member.listForWorkspace('org/temp')).isNotEmpty,
      isTrue,
    );

    // Delete — the same two-step the `workspace_delete` tool handler runs:
    // registry disk delete + member-cache eviction (cascade).
    await ws.delete('org/temp');
    init.registries.member.evictWorkspace('org/temp');

    // wd2 — both homes gone, no members resolvable, no resurrection.
    expect(metaDir.existsSync(), isFalse, reason: 'metadata dir must be gone');
    expect(
      contentDir.existsSync(),
      isFalse,
      reason: '.mbd content bundle must be gone (the resurrection source)',
    );
    expect(
      await init.registries.member.listForWorkspace('org/temp'),
      isEmpty,
      reason: 'a deleted workspace must expose no members',
    );
    expect(
      (await ws.list()).any((w) => w.id == 'org/temp'),
      isFalse,
      reason: 'a deleted workspace must not appear in the list',
    );
  });
}
