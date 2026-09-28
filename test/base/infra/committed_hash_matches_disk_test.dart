/// After a save, the canonical's committed hash equals the hash of the same
/// bundle read back from disk. App Builder's external-change check compares
/// the two whenever the bundle folder changes; the in-memory map lists `ui`
/// before `requires`/`extensions` while the re-merged disk map lists it last,
/// so an order-sensitive hash read the studio's own save as an outside edit
/// and marked a just-created (or just-exported) project unsaved.
library;

import 'dart:io';

import 'package:appplayer_studio/base.dart'
    show CanonicalPatch, LayerId, WorkspaceCanonicalImpl, canonicalContentHash;
import 'package:appplayer_studio/builtin_api.dart' show PatchOp, UserOriginator;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('content hash ignores key order', () {
    expect(
      canonicalContentHash(<String, dynamic>{
        'a': 1,
        'b': <String, dynamic>{
          'x': 1,
          'y': <dynamic>[1, 2],
        },
      }),
      canonicalContentHash(<String, dynamic>{
        'b': <String, dynamic>{
          'y': <dynamic>[1, 2],
          'x': 1,
        },
        'a': 1,
      }),
    );
    expect(
      canonicalContentHash(<String, dynamic>{
        'a': <dynamic>[1, 2],
      }),
      isNot(
        canonicalContentHash(<String, dynamic>{
          'a': <dynamic>[2, 1],
        }),
      ),
    );
  });

  test(
    'committed hash after save = hash of the bundle read from disk',
    () async {
      final dir = Directory.systemTemp.createTempSync('committed_hash_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bundle = p.join(dir.path, 'serving.mbd');
      final fs = FileWorkspaceFsPort();
      final c = WorkspaceCanonicalImpl(
        fsPort: fs,
        validator: SpecValidatorImpl(),
      );
      await c.open(bundle);
      addTearDown(c.dispose);
      await c.applyAtomic(
        CanonicalPatch(
          layer: LayerId.appStructure,
          ops: <PatchOp>[PatchOp(op: 'add', path: '/ui/title', value: 'Hash')],
          originator: const UserOriginator(),
        ),
      );
      await c.save();
      expect(c.isDirty, isFalse);
      final disk = await fs.readJson(bundle);
      expect(c.committedHash, canonicalContentHash(disk!));
    },
  );
}
