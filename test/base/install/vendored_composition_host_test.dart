/// The vendored copy of `composition_host` must not drift from its recipe.
///
/// This is the OPEN tree and must build from a standalone clone, where a path
/// dependency on a `publish_to: none` recipe outside the repo cannot resolve —
/// so the copy is deliberate (Studio Pro depends on the recipe by path and
/// keeps no copy). What is NOT deliberate is the copy quietly diverging: the
/// recipe is what another host reads and builds against, so a fix applied to
/// only one of them leaves the reference describing behaviour the platform no
/// longer has.
///
/// Regenerate with `debug/tool/sync_composition_host_fork.sh`, never by hand.
///
/// Skipped, loudly, when the recipe is not on disk — a standalone clone of the
/// open tree has the copy but not the monorepo source.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vendored file → its path within the recipe's `lib/`.
const _vendored = <String, String>{
  'lib/src/base/install/composition_host/composition_host.dart':
      'composition_host.dart',
  'lib/src/base/install/composition_host/src/composition_host.dart':
      'src/composition_host.dart',
};

/// Relative to the package root (`flutter test` runs with that cwd):
/// `debug/standard` → up four → monorepo root.
const _recipeLib =
    '../../../../os/core/brain_kernel/recipes/composition_host/lib';

/// The header the sync script stamps ends where the copied body begins; the
/// body is what must not move alone.
String _bodyAfterHeader(String source, String path) {
  const marker = '\n// Everything below this header is byte-identical';
  final i = source.indexOf(marker);
  if (i < 0) return source;
  final nl = source.indexOf('\n', i + marker.length);
  return source.substring(nl + 1);
}

void main() {
  test('vendored composition_host matches the recipe', () {
    final recipeDir = Directory(_recipeLib);
    if (!recipeDir.existsSync()) {
      // ignore: avoid_print
      print('SKIP: recipe not on disk (standalone open-tree checkout) — '
          'drift cannot be checked here.');
      return;
    }

    expect(_vendored, isNotEmpty);
    for (final entry in _vendored.entries) {
      final copyFile = File(entry.key);
      final recipeFile = File('$_recipeLib/${entry.value}');

      expect(copyFile.existsSync(), isTrue,
          reason: '${entry.key} is missing — run '
              'debug/tool/sync_composition_host_fork.sh');
      expect(recipeFile.existsSync(), isTrue,
          reason: 'recipe file ${entry.value} vanished — the vendor map in '
              'this test is stale');

      final copy = copyFile.readAsStringSync();
      expect(copy.contains('VENDORED from'), isTrue,
          reason: '${entry.key} must say it is a copy, and where from');

      expect(
        _bodyAfterHeader(copy, entry.key),
        recipeFile.readAsStringSync(),
        reason: 'fix at the recipe and re-run '
            'debug/tool/sync_composition_host_fork.sh — never edit only the '
            'copy (${entry.key})',
      );
    }
  });

  test('the vendor map covers every dart file in the recipe', () {
    final recipeDir = Directory(_recipeLib);
    if (!recipeDir.existsSync()) {
      // ignore: avoid_print
      print('SKIP: recipe not on disk (standalone open-tree checkout).');
      return;
    }
    // A file added to the recipe must be vendored too — otherwise the copy
    // silently lacks it and the first test above still passes.
    final onDisk = recipeDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path.substring(_recipeLib.length + 1))
        .toSet();
    expect(onDisk, _vendored.values.toSet(),
        reason: 'recipe file set changed — re-run the sync script and update '
            'the vendor map in this test');
  });
}
