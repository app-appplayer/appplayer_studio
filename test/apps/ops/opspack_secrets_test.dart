/// opspack carries a passphrase-sealed credential blob (ops-asset-management
/// P4, opspack includeSecrets). These cover the crypto-free packaging side —
/// the manifest flag, the opaque `credentials.sealed` entry round-trip, and the
/// invariant that the blob is never unpacked to disk on import. The sealing
/// itself is the host `PassphraseSealer` (covered by credentials_migration).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/portability/opspack.dart';

void main() {
  late Directory tmp;
  late Directory wsDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('opspack_secrets_test');
    wsDir = Directory('${tmp.path}/ws')..createSync(recursive: true);
    File('${wsDir.path}/workspace.yaml').writeAsStringSync('id: ws-x\n');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('without sealedCredentials → includeSecrets false, no blob', () async {
    final pack = await Opspack.exportWorkspace(
      workspaceDir: wsDir,
      workspaceId: 'ws-x',
    );
    expect(pack.manifest.includeSecrets, isFalse);
    expect(Opspack.extractSealedCredentials(pack.bytes), isNull);
  });

  test('sealedCredentials is carried verbatim and flips includeSecrets',
      () async {
    const blob = '{"v":1,"kdf":"pbkdf2","ct":"deadbeef"}';
    final pack = await Opspack.exportWorkspace(
      workspaceDir: wsDir,
      workspaceId: 'ws-x',
      sealedCredentials: blob,
    );
    expect(pack.manifest.includeSecrets, isTrue);
    expect(Opspack.extractSealedCredentials(pack.bytes), blob);
  });

  test('manifest includeSecrets survives json round-trip', () {
    final m = OpspackManifest(
      formatVersion: OpspackManifest.currentFormatVersion,
      sourceWorkspaceId: 'ws-x',
      workspaceType: 'personal',
      createdAt: DateTime.utc(2026, 6, 28),
      includeFacts: false,
      includeSecrets: true,
      contents: const ['workspace.yaml'],
    );
    final back = OpspackManifest.fromJson(m.toJson());
    expect(back.includeSecrets, isTrue);
  });

  test('import never unpacks the sealed blob to disk', () async {
    const blob = '{"v":1,"ct":"x"}';
    final pack = await Opspack.exportWorkspace(
      workspaceDir: wsDir,
      workspaceId: 'ws-x',
      sealedCredentials: blob,
    );
    final packFile = File('${tmp.path}/ws-x.opspack')
      ..writeAsBytesSync(pack.bytes);
    final root = Directory('${tmp.path}/import')..createSync();
    final id = await Opspack.importWorkspace(
      packFile: packFile,
      workspacesRoot: root,
    );
    // The workspace file is restored, but credentials.sealed must NOT be.
    expect(File('${root.path}/$id/workspace.yaml').existsSync(), isTrue);
    expect(File('${root.path}/$id/credentials.sealed').existsSync(), isFalse);
    // The blob is still recoverable from the pack itself, via the API.
    expect(Opspack.extractSealedCredentials(packFile.readAsBytesSync()), blob);
  });
}
