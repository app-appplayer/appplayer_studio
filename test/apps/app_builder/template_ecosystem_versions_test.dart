/// Guard: the template ecosystem versions — the pins an emitted app gets in
/// its `pubspec.yaml` — MUST match the studio's own `pubspec.yaml`.
///
/// An emitted app runs on the runtime the studio was built and tested against,
/// so a drift here ships apps pinned to an untested (usually older) runtime.
/// The versions live in the seed (`template_ecosystem_versions.dart`) and are
/// meant to be synced with the studio's deps on every version-up, alongside
/// the agent knowledge seed. This test turns a forgotten sync into a red
/// build instead of a silently stale template.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/app_builder/conv/llm_server_guide.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/template_ecosystem_versions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  // Tests run with the package root as CWD.
  final pubspec =
      loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
  final deps = pubspec['dependencies'] as YamlMap;

  String studioPin(String name) {
    final v = deps[name];
    expect(
      v,
      isA<String>(),
      reason:
          '`$name` must be a plain version-constraint dependency in the '
          'studio pubspec for the template seed to mirror it.',
    );
    return v as String;
  }

  test('template seed versions match the studio pubspec (sync-on-version-up)', () {
    expect(
      kTemplateFlutterMcpUiRuntime,
      studioPin('flutter_mcp_ui_runtime'),
      reason:
          'flutter_mcp_ui_runtime drift — sync '
          'kTemplateFlutterMcpUiRuntime with the studio pubspec.',
    );
    expect(
      kTemplateMcpServer,
      studioPin('mcp_server'),
      reason:
          'mcp_server drift — sync kTemplateMcpServer with the studio '
          'pubspec.',
    );
    expect(
      kTemplateMcpBundle,
      studioPin('mcp_bundle'),
      reason:
          'mcp_bundle drift — sync kTemplateMcpBundle with the studio '
          'pubspec.',
    );
  });

  // The guide the LLM receives when it writes a server by hand used to restate
  // the pins as literal text, and had gone stale at `^2.0.0` while the
  // generator emitted `^2.1.x`. The guide now interpolates the same seed, so
  // the only way it can be wrong is if that interpolation is removed.
  test('the LLM server guide carries the seed pins, not a stale copy', () {
    expect(
      mcpServerDartPattern,
      contains('mcp_server: $kTemplateMcpServer'),
      reason:
          'the hand-written-server guide must quote the seed pin — a literal '
          'version here goes stale the moment the studio version-ups.',
    );
    expect(mcpServerDartPattern, contains('mcp_bundle: $kTemplateMcpBundle'));
  });
}
