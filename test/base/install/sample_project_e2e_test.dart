import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

/// Validates the example/sample_project.apbproj layout — the canonical
/// app-in-project structure. The .apbproj container holds project
/// metadata + a nested app.mbd; loading the inner bundle should be a
/// plain readBundleAt against `<project>/<bundleSubdir>`.
///
/// Builder packages (e.g. app_builder_vibe.mbd) follow the same
/// pattern — they open a project, edit its app.mbd in place, and
/// re-save. The host's project / canonical layer is a separate
/// concern; this test validates only the file shape contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String _projectRoot() {
    return p.normalize(
      p.join(Directory.current.path, 'example', 'sample_project.apbproj'),
    );
  }

  group('sample_project.apbproj', () {
    test('project.json has the expected meta fields', () {
      final raw =
          File(p.join(_projectRoot(), 'project.json')).readAsStringSync();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['name'], 'Sample Project');
      expect(j['bundleSubdir'], 'app.mbd');
      expect(j['schemaVersion'], '1.0.0');
    });

    test('inner app.mbd parses through readBundleAt', () {
      final root = _projectRoot();
      final j =
          jsonDecode(File(p.join(root, 'project.json')).readAsStringSync())
              as Map<String, dynamic>;
      final bundleSubdir = j['bundleSubdir'] as String;
      final appPath = p.join(root, bundleSubdir);
      final bundle = readBundleAt(appPath)!;
      expect(bundle.bundleId, 'com.makemind.examples.sample_app');
      expect(bundle.shortId, 'sample_app');
      expect(bundle.displayLabel, 'Sample App');
      expect(bundle.tools, isNull);
      expect(bundle.agents, isNull);
      expect(bundle.uiEntry!.kind, 'mcp_ui_dsl');
      expect(bundle.uiEntry!.path, 'ui/app.json');
      // requires section is empty — fully portable
      expect(bundle.requires!.builtinAtoms, isEmpty);
      expect(bundle.requires!.builtinTools, isEmpty);
    });

    test('inner app.mbd validates with no errors', () {
      final root = _projectRoot();
      final j =
          jsonDecode(File(p.join(root, 'project.json')).readAsStringSync())
              as Map<String, dynamic>;
      final appPath = p.join(root, j['bundleSubdir'] as String);
      final bundle = readBundleAt(appPath)!;
      final issues = BundleManifestValidator.validate(bundle);
      final errors =
          issues
              .where((i) => i.severity == ManifestIssueSeverity.error)
              .toList();
      expect(
        errors,
        isEmpty,
        reason: errors
            .map((e) => '${e.code} @ ${e.pointer}: ${e.message}')
            .join('\n'),
      );
    });

    test('asset path resolution stays inside the inner bundle', () {
      final root = _projectRoot();
      final j =
          jsonDecode(File(p.join(root, 'project.json')).readAsStringSync())
              as Map<String, dynamic>;
      final appPath = p.join(root, j['bundleSubdir'] as String);
      final bundle = readBundleAt(appPath)!;
      // resolve a path inside the inner bundle
      final ui = bundle.resolveAsset('ui/app.json');
      expect(File(ui).existsSync(), isTrue);
      // attempting to escape upward into the project container is
      // refused — the bundle root is `<project>/app.mbd`, not the
      // project itself.
      expect(() => bundle.resolveAsset('../project.json'), throwsStateError);
    });
  });
}
