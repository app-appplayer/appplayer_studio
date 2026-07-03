import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:appplayer_studio/src/base/settings/manifest_field_inheritance.dart';

// Per-domain project location: the domain's Workspace-folder override
// (package_settings/<safe>.json) must WIN over the studio-wide inherited
// workspaceDir — and showing the field without consuming it was the
// display-only trap every built-in had (fixed 2026-07-03).
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('wsdir_'));
  tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

  String overrides(Map<String, Object?> json) {
    final f = File('${tmp.path}/pkg.json');
    f.writeAsStringSync(jsonEncode(json));
    return f.path;
  }

  test('domain override wins over the inherited studio value', () {
    final file = overrides({'workspaceDir': '/domain/dir'});
    expect(
      effectiveWorkspaceDir(
        inherited: {'workspaceDir': '/studio/dir'},
        overridesFile: file,
      ),
      '/domain/dir',
    );
  });

  test('falls back to inherited when no override; null when neither', () {
    final file = overrides({'somethingElse': true});
    expect(
      effectiveWorkspaceDir(
        inherited: {'workspaceDir': '/studio/dir'},
        overridesFile: file,
      ),
      '/studio/dir',
    );
    expect(
      effectiveWorkspaceDir(inherited: const {}, overridesFile: file),
      isNull,
    );
  });

  test('empty-string override does not mask the inherited value', () {
    final file = overrides({'workspaceDir': ''});
    expect(
      effectiveWorkspaceDir(
        inherited: {'workspaceDir': '/studio/dir'},
        overridesFile: file,
      ),
      '/studio/dir',
    );
  });

  test('missing/absent file and empty path are safe no-ops', () {
    expect(readPackageOverrides(''), isEmpty);
    expect(readPackageOverrides('${tmp.path}/nope.json'), isEmpty);
    expect(
      effectiveWorkspaceDir(
        inherited: {'workspaceDir': '/studio/dir'},
        overridesFile: '${tmp.path}/nope.json',
      ),
      '/studio/dir',
    );
  });
}
