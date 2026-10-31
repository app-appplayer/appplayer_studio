/// The vendored copy of `plugin_host` must not drift from its recipe.
///
/// This is the OPEN tree and must build from a standalone clone, where a path
/// dependency on a `publish_to: none` recipe outside the repo cannot resolve —
/// so the copy is deliberate. What is NOT deliberate is the copy quietly
/// diverging: a plugin's behaviour (destructive hints, tool-list changes, door
/// connections) lives in the recipe.
///
/// Regenerate with `debug/tool/sync_plugin_host_fork.sh`, never by hand.
///
/// Skipped, loudly, when the recipe is not on disk.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vendored file → its path within the recipe's `lib/`.
const _vendored = <String, String>{
  'lib/src/base/install/plugin_host/plugin_host.dart': 'plugin_host.dart',
  'lib/src/base/install/plugin_host/src/plugin_access.dart':
      'src/plugin_access.dart',
  'lib/src/base/install/plugin_host/src/plugin_host.dart':
      'src/plugin_host.dart',
  'lib/src/base/install/plugin_host/src/plugin_source.dart':
      'src/plugin_source.dart',
};

/// Relative to the package root: `debug/standard` → up four → monorepo root.
const _recipeLib = '../../../../os/core/brain_kernel/recipes/plugin_host/lib';

String _bodyAfterHeader(String source) {
  const marker = '\n// Everything below this header is byte-identical';
  final i = source.indexOf(marker);
  if (i < 0) return source;
  final nl = source.indexOf('\n', i + marker.length);
  return source.substring(nl + 1);
}

void main() {
  test('vendored plugin_host matches the recipe', () {
    final recipeDir = Directory(_recipeLib);
    if (!recipeDir.existsSync()) return;
    for (final entry in _vendored.entries) {
      final copyFile = File(entry.key);
      final recipeFile = File('$_recipeLib/${entry.value}');
      expect(copyFile.existsSync(), isTrue,
          reason: '${entry.key} is missing — run '
              'debug/tool/sync_plugin_host_fork.sh');
      expect(recipeFile.existsSync(), isTrue,
          reason: 'recipe file ${entry.value} vanished — the vendor map in '
              'this test is stale');
      final copy = copyFile.readAsStringSync();
      expect(copy.contains('VENDORED from'), isTrue,
          reason: '${entry.key} must say it is a copy, and where from');
      expect(
        _bodyAfterHeader(copy),
        recipeFile.readAsStringSync(),
        reason: 'fix at the recipe and re-run '
            'debug/tool/sync_plugin_host_fork.sh — never edit only the copy '
            '(${entry.key})',
      );
    }
  });

  test('the vendor map covers every dart file in the recipe', () {
    final recipeDir = Directory(_recipeLib);
    if (!recipeDir.existsSync()) return;
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
