/// `bundle://` bytes come from the project folder — and only from there.
///
/// Without this reader the runtime declares the form absent and every surface
/// that needs BYTES draws an empty box (`lottieAnimation`, `pdfViewer`, a media
/// waveform). Images kept working the whole time because they resolve through
/// a provider, which is why the gap read as "lottie is broken".
///
/// The containment half is not decoration. A document is authored content, not
/// a trusted program: a reference that walks out of the bundle would read
/// whatever the studio process can.
@TestOn('vm')
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/media/studio_bundle_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String bundle;
  late Future<List<int>?> Function(String) read;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bundle_assets_');
    bundle = p.join(tmp.path, 'thing.mbd');
    Directory(p.join(bundle, 'ui')).createSync(recursive: true);
    File(p.join(bundle, 'anim.json')).writeAsStringSync('{"v":"5.7.4"}');
    File(p.join(bundle, 'ui', 'nested.txt')).writeAsStringSync('nested');
    File(p.join(tmp.path, 'outside.txt')).writeAsStringSync('secret');
    read = studioBundleAssetReader(bundle);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a file in the bundle comes back as bytes', () async {
    final bytes = await read('anim.json');
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!), '{"v":"5.7.4"}');
  });

  test('a nested path resolves', () async {
    expect(String.fromCharCodes((await read('ui/nested.txt'))!), 'nested');
  });

  test('a missing file is null, not an exception', () async {
    // The surface turns null into `onError` + nothing drawn; a throw would
    // take the frame down instead.
    expect(await read('nope.json'), isNull);
  });

  test('an empty path is null', () async {
    expect(await read(''), isNull);
  });

  test('a path that walks out of the bundle is refused', () async {
    // The file exists and the process can read it — the refusal is the point.
    expect(File(p.join(tmp.path, 'outside.txt')).existsSync(), isTrue);
    expect(await read('../outside.txt'), isNull);
    expect(await read('ui/../../outside.txt'), isNull);
  });

  test('an absolute path does not escape either', () async {
    // `join` drops the root and returns the absolute path verbatim, so this
    // would otherwise read anything on disk.
    expect(await read(p.join(tmp.path, 'outside.txt')), isNull);
  });

  test('an empty file is not an asset', () async {
    // Zero bytes would otherwise reach the surface and draw an empty frame —
    // which looks exactly like the capability being absent.
    File(p.join(bundle, 'empty.json')).writeAsStringSync('');
    expect(await read('empty.json'), isNull);
  });

  test('a directory is not bytes', () async {
    expect(await read('ui'), isNull);
  });
}
