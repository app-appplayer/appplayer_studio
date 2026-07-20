/// Unit coverage for [LocalServerManager] — the local-server orchestration
/// around the shared client-host registry: the discovered-board tab open
/// ([openServed]), the Home INSTALLED APPS tiles, and record removal (which
/// must also purge the keychain credential). The connect / reconnect render
/// paths need a live served MCP connection and are exercised end-to-end in the
/// discovery + served-service integration tests; here we lock the pure routing
/// and store/vault side-effects with an empty real client host.
@TestOn('vm')
library;

import 'dart:io';

import 'package:appplayer_secure/appplayer_secure.dart';
import 'package:appplayer_studio/src/base/servers/local_server_manager.dart';
import 'package:appplayer_studio/src/base/servers/local_server_store.dart';
import 'package:appplayer_studio/src/base/servers/served_service.dart'
    show ServedServiceBody;
import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One captured `openTab` invocation.
class _OpenedTab {
  _OpenedTab(this.key, this.label, this.builder);
  final String key;
  final String label;
  final WidgetBuilder builder;
}

void main() {
  late Directory tmp;
  late McpClientKernelHost clientHost;
  late LocalServerStore store;
  late LocalServerCredentialVault vault;
  late InMemorySecureStorage storage;
  late List<_OpenedTab> opened;
  late LocalServerManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local_server_manager_test');
    clientHost = McpClientKernelHost();
    store = LocalServerStore(tmp.path);
    storage = InMemorySecureStorage();
    vault = LocalServerCredentialVault(storage);
    opened = <_OpenedTab>[];
    manager = LocalServerManager(
      clientHost: clientHost,
      store: store,
      vault: vault,
      openTab: ({required key, required label, required builder}) =>
          opened.add(_OpenedTab(key, label, builder)),
    );
  });

  tearDown(() async {
    await clientHost.shutdown();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('openServed', () {
    test('opens a stable local-server tab keyed by connection id', () {
      manager.openServed('board:acme.lab', title: 'Lab Board');
      expect(opened, hasLength(1));
      expect(opened.single.key, 'local-server:board:acme.lab');
      expect(opened.single.label, 'Lab Board');
    });

    test('falls back to the connection id when no title is given', () {
      manager.openServed('ble:dev-1');
      expect(opened.single.label, 'ble:dev-1');
    });

    testWidgets('the tab body wires a ServedServiceBody at the connection id',
        (tester) async {
      manager.openServed('board:acme.lab');
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        })),
      );
      // Materialize the builder; openServed never touches the host, so this is
      // a pure structural check (no reconnect, not mounted).
      final built = opened.single.builder(ctx);
      expect(built, isA<ServedServiceBody>());
      expect((built as ServedServiceBody).connectionId, 'board:acme.lab');
    });
  });

  group('tiles', () {
    test('one tile per recorded server, labelled by record name', () {
      store.put(const LocalServerRecord(
        id: 'https://a/mcp',
        transport: KernelTransportKind.streamableHttp,
        endpoint: 'https://a/mcp',
        name: 'Server A',
      ));
      store.put(const LocalServerRecord(
        id: '/bin/srv',
        transport: KernelTransportKind.stdio,
        command: '/bin/srv',
        name: 'Local B',
      ));
      final tiles = manager.tiles();
      expect(tiles.map((t) => t.label), containsAll(<String>['Server A', 'Local B']));
      expect(tiles, hasLength(2));
    });

    test('no records → no tiles', () {
      expect(manager.tiles(), isEmpty);
    });
  });

  group('remove (via tile onRemove)', () {
    test('drops the record and purges the keychain credential', () async {
      final ref = LocalServerCredentialVault.refFor('https://a/mcp');
      await vault.write(ref, 'bearer-xyz');
      store.put(LocalServerRecord(
        id: 'https://a/mcp',
        transport: KernelTransportKind.streamableHttp,
        endpoint: 'https://a/mcp',
        name: 'Server A',
        credentialRef: ref,
      ));
      expect(await vault.read(ref), 'bearer-xyz');

      await manager.tiles().single.onRemove!();

      expect(store.list(), isEmpty);
      expect(await vault.read(ref), isNull);
    });

    test('a credential-less record removes cleanly', () async {
      store.put(const LocalServerRecord(
        id: '/bin/srv',
        transport: KernelTransportKind.stdio,
        command: '/bin/srv',
        name: 'Local B',
      ));
      await manager.tiles().single.onRemove!();
      expect(store.list(), isEmpty);
    });
  });
}
