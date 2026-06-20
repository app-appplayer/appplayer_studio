/// Unit tests for `writeStringAtomic` in `util/atomic_write.dart`.
///
/// Boot-independent: real temp-dir FS I/O, no Flutter widgets.
///
/// Scenarios:
///   aw1  creates the target file with correct content
///   aw2  creates parent directory when missing
///   aw3  overwrites existing file atomically (no torn state)
///   aw4  no lingering .tmp file after completion
///   aw5  empty string written correctly
///   aw6  unicode content written and read back correctly
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/ops/util/atomic_write.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('atomic_write_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // aw1
  test('aw1 creates target file with correct content', () async {
    final file = File(p.join(tmp.path, 'test.txt'));
    await writeStringAtomic(file, 'hello world');
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), 'hello world');
  });

  // aw2
  test('aw2 creates parent directory when missing', () async {
    final nested = File(p.join(tmp.path, 'deep', 'dir', 'file.txt'));
    await writeStringAtomic(nested, 'nested content');
    expect(await nested.exists(), isTrue);
    expect(await nested.readAsString(), 'nested content');
  });

  // aw3
  test('aw3 overwrites existing file with new content', () async {
    final file = File(p.join(tmp.path, 'overwrite.txt'));
    await writeStringAtomic(file, 'first');
    await writeStringAtomic(file, 'second');
    expect(await file.readAsString(), 'second');
  });

  // aw4
  test('aw4 no lingering .tmp file after successful write', () async {
    final file = File(p.join(tmp.path, 'clean.txt'));
    await writeStringAtomic(file, 'data');
    final tmp2 = File('${file.path}.tmp');
    expect(await tmp2.exists(), isFalse);
  });

  // aw5
  test('aw5 empty string is written and read back correctly', () async {
    final file = File(p.join(tmp.path, 'empty.txt'));
    await writeStringAtomic(file, '');
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), '');
  });

  // aw6
  test('aw6 unicode content round-trips correctly', () async {
    const content = '안녕하세요 🎉 — makemind\n日本語テスト\nÜberprüfung';
    final file = File(p.join(tmp.path, 'unicode.txt'));
    await writeStringAtomic(file, content);
    expect(await file.readAsString(), content);
  });
}
