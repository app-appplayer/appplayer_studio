import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const registered = <String>{
    'notes.save',
    'notes.board.summary',
    'notes.editor.open',
    'notes.editor.close',
    'studio.fs.read',
  };
  String resolve(String name, String? ns) => resolveBundleToolName(
    name,
    namespace: ns,
    isRegistered: registered.contains,
  );

  test('own namespace first, then the name as written', () {
    expect(resolve('save', 'notes'), 'notes.save');
    expect(resolve('board.summary', 'notes'), 'notes.board.summary');
    expect(resolve('notes.save', 'notes'), 'notes.save');
    expect(resolve('studio.fs.read', 'notes'), 'studio.fs.read');
    expect(resolve('missing', 'notes'), 'missing');
  });

  test('outside a bundle only full names reach', () {
    expect(resolve('save', null), 'save');
    expect(resolve('save', ''), 'save');
    expect(resolve('notes.save', null), 'notes.save');
  });

  test('allowlist patterns resolve the same way, stars included', () {
    String pattern(String p) =>
        resolveBundleToolPattern(p, namespace: 'notes', registered: registered);
    expect(pattern('save'), 'notes.save');
    expect(pattern('editor.*'), 'notes.editor.*');
    expect(pattern('studio.fs.*'), 'studio.fs.*');
    expect(pattern('bk.fact.*'), 'bk.fact.*');
    expect(
      resolveBundleToolPattern('save', namespace: null, registered: registered),
      'save',
    );
  });
}
