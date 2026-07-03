import 'dart:convert' show JsonEncoder;
import 'dart:io';

import 'package:path/path.dart' as p;

/// Root marker for a Form Builder project — signals "this directory is a
/// form project" (templates + drafts + issues live in its FactGraph and
/// `forms/`). Mirrors App Builder's `project.apbproj` / Ops's
/// `project.opsproj`.
const String formProjectMarker = 'project.formproj';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Materialise the Form Builder project skeleton into [projectDir].
/// Idempotent — existing files are overwritten so re-seeding stays clean.
///
/// ```
/// <projectDir>/
///   project.formproj          — root marker (id · name · createdAt)
///   project.mbd/manifest.json — project bundle (mcp_bundle canonical shape)
///   forms/                    — issued artifacts land here (per issue number)
/// ```
///
/// Templates / drafts / issues are NOT seeded — they are facts the user (or
/// an LLM through the tools) creates; boot must not auto-seed operational
/// data (seed-cleanliness contract).
Future<void> applyFormProjectSeed(String projectDir, String projectName) async {
  final createdAt = DateTime.now().toUtc().toIso8601String();
  final marker = File(p.join(projectDir, formProjectMarker));
  await marker.parent.create(recursive: true);
  await marker.writeAsString(
    _pretty.convert(<String, dynamic>{
      'schemaVersion': '1.0.0',
      'id': projectName,
      'name': projectName,
      'kind': 'form_project',
      'createdAt': createdAt,
    }),
  );
  final manifest = File(p.join(projectDir, 'project.mbd', 'manifest.json'));
  await manifest.parent.create(recursive: true);
  await manifest.writeAsString(
    _pretty.convert(<String, dynamic>{
      'schemaVersion': '1.0.0',
      'manifest': <String, dynamic>{
        'id': '$projectName.project',
        'name': projectName,
        'version': '0.1.0',
        'type': 'library',
        'description':
            'Form Builder project bundle — form templates, drafts and '
            'issued documents accumulate in this project\'s FactGraph.',
      },
      'requires': <String, dynamic>{'builtinAtoms': <String>[]},
    }),
  );
  await Directory(p.join(projectDir, 'forms')).create(recursive: true);
}

/// True when [projectDir] holds a Form Builder project (root marker
/// exists). `_openProject` refuses arbitrary directories with this.
bool isFormProjectDir(String projectDir) {
  return File(p.join(projectDir, formProjectMarker)).existsSync();
}
