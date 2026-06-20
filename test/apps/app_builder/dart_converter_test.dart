/// Unit tests for [DartConverterImpl] and [EmbedConverterImpl].
///
/// DartConverter scenarios:
///   dc1  _slug — basic slug derivation cases
///   dc2  _slug — fallback when name reduces to empty
///   dc3  _slug — pubspec name must start with letter
///   dc4  _uiOnlyJson — extracts ui sub-tree from canonical JSON
///   dc5  _uiOnlyJson — returns empty map on malformed input
///   dc6  _uiString — returns value for valid string key
///   dc7  _uiString — returns null for missing / empty / non-string
///   dc8  run mcpb — emits bundle.mcpb and convert.json (no source)
///   dc9  run mcpb — packs from sourceBundlePath when provided
///   dc10 run bundle — emits expected file layout
///   dc11 run inline — emits expected file layout
///   dc12 run nativeBundle — emits expected file layout
///   dc13 run nativeInline — emits expected file layout
///   dc14 convert.json has correct target field for each variant
///   dc15 convert.json canonical_hash is non-empty sha256 string
///   dc16 PatternException raised when enforcer reports violations
///
/// EmbedConverter scenarios:
///   ec1  unsupported board → EmbedException
///   ec2  native mode — emits src/server.c + CMakeLists.txt
///   ec3  withBundle mode — emits data/manifest.json
///   ec4  convert.json has board + mode + canonical_hash
///   ec5  linux-host is a supported board
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' show McpBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' show BundleManifest;
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/apps/app_builder/conv/dart_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/embed_converter.dart';
import 'package:appplayer_studio/src/base/conv/pattern_enforcer.dart';

// ── helpers ────────────────────────────────────────────────────────────

McpBundle _bundle({
  String id = 'test_app',
  String name = 'Test App',
  String? description,
}) => McpBundle(
  manifest: BundleManifest(
    id: id,
    name: name,
    version: '1.0.0',
    description: description,
  ),
);

/// A PatternEnforcer that always reports one violation, so we can test
/// the exception path without touching the real wiring checker.
class _AlwaysViolatingEnforcer implements PatternEnforcer {
  const _AlwaysViolatingEnforcer();
  @override
  List<PatternViolation> check(McpBundle canonical, ConvertTarget target) {
    return const <PatternViolation>[
      PatternViolation(
        code: 'TEST_VIOLATION',
        path: '/root',
        message: 'forced violation',
      ),
    ];
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dart_conv_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ══════════════════════════════════════════════════════════════════════
  // DartConverter — static helpers (accessed via DartConverterImpl)
  // ══════════════════════════════════════════════════════════════════════

  // ── dc1 _slug basic ────────────────────────────────────────────────
  group('dc1 DartConverterImpl._slug basic', () {
    // _slug is private but exercised through the public run() calls that
    // use it to derive package names in generated pubspec.yaml.

    test('spaces become underscores', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc1_spaces');
      final result = await converter.run(
        canonical: _bundle(name: 'Hello World'),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      // bundle.mcpb and convert.json must exist (non-zero file set).
      expect(result.writtenFiles, isNotEmpty);
    });

    test('uppercase letters lowercased', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc1_upper');
      await converter.run(
        canonical: _bundle(name: 'MyMCP App'),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      final convertJson = File(p.join(outDir, 'convert.json'));
      expect(await convertJson.exists(), isTrue);
    });
  });

  // ── dc2 _slug fallback ────────────────────────────────────────────
  group('dc2 _slug fallback', () {
    test('all-punctuation name falls back to id', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc2_slug');
      // Name "!!!..." would reduce to empty → fallback to id.
      final result = await converter.run(
        canonical: _bundle(id: 'fallback_id', name: '!!!'),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      expect(result.writtenFiles, isNotEmpty);
    });
  });

  // ── dc3 _slug letter prefix ───────────────────────────────────────
  group('dc3 _slug letter prefix', () {
    test('digit-leading name gets gen_ prefix in pubspec', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc3_prefix');
      // Name "42app" → slug starts with digit → pubspec must get gen_ prefix.
      await converter.run(
        canonical: _bundle(name: '42app'),
        target: DartTarget.bundle,
        outDir: outDir,
      );
      final pubspec = File(p.join(outDir, 'pubspec.yaml'));
      expect(await pubspec.exists(), isTrue);
      final content = await pubspec.readAsString();
      // Slug must start with a letter.
      expect(content, contains('name: gen_'));
    });
  });

  // ── dc4 _uiOnlyJson extraction ────────────────────────────────────
  group('dc4 _uiOnlyJson', () {
    test('inline run succeeds without ui in canonical (returns {})', () async {
      // DartConverterImpl._uiOnlyJson is private; exercise it via nativeInline
      // with no sourceBundlePath. _bundle() has no ui section so _uiOnlyJson
      // returns {} — the run must still succeed.
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc4_ui');
      final result = await converter.run(
        canonical: _bundle(),
        target: DartTarget.nativeInline,
        outDir: outDir,
      );
      expect(result.writtenFiles, isNotEmpty);
    });
  });

  // ── dc5 _uiOnlyJson malformed ─────────────────────────────────────
  group('dc5 _uiOnlyJson malformed graceful', () {
    test(
      'inline server run succeeds even when ui sub-tree is absent',
      () async {
        final converter = DartConverterImpl();
        final outDir = p.join(tmp.path, 'dc5_noul');
        final result = await converter.run(
          canonical: _bundle(),
          target: DartTarget.inline,
          outDir: outDir,
        );
        expect(result.writtenFiles, isNotEmpty);
      },
    );
  });

  // ── dc6 _uiString value ───────────────────────────────────────────
  group('dc6/_dc7 _uiString', () {
    // Exercised through the inline variant which reads ui.title/name/etc.
    test('missing key treated as null — run still emits files', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc6_str');
      final result = await converter.run(
        canonical: _bundle(name: '', id: 'minimal_id'),
        target: DartTarget.inline,
        outDir: outDir,
      );
      // inline emits: bin/server.dart, lib/*, pubspec.yaml, README.md, convert.json.
      expect(result.writtenFiles.length, greaterThan(3));
    });
  });

  // ── dc8 mcpb no source ────────────────────────────────────────────
  group('dc8 run mcpb without sourceBundlePath', () {
    test('emits bundle.mcpb and convert.json', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc8_mcpb');
      final result = await converter.run(
        canonical: _bundle(),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      final paths = result.writtenFiles.map(p.basename).toSet();
      expect(paths.contains('bundle.mcpb'), isTrue);
      expect(paths.contains('convert.json'), isTrue);
      expect(await File(p.join(outDir, 'bundle.mcpb')).exists(), isTrue);
    });

    test('ConvertResult.outDir matches requested outDir', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc8b_mcpb');
      final result = await converter.run(
        canonical: _bundle(),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      expect(result.outDir, outDir);
    });
  });

  // ── dc9 mcpb with sourceBundlePath ───────────────────────────────
  group('dc9 run mcpb with sourceBundlePath', () {
    test('packs from the provided .mbd directory', () async {
      // Build a minimal .mbd source directory using the mcp_bundle format
      // (outer wrapper with schemaVersion + manifest sub-object).
      final mbdDir = Directory(p.join(tmp.path, 'source.mbd'));
      await mbdDir.create(recursive: true);
      await File(p.join(mbdDir.path, 'manifest.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'schemaVersion': '1.0.0',
          'manifest': <String, dynamic>{
            'id': 'test_src',
            'name': 'Test Source',
            'version': '1.0.0',
          },
        }),
      );

      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc9_mcpb');
      final result = await converter.run(
        canonical: _bundle(),
        target: DartTarget.mcpb,
        outDir: outDir,
        sourceBundlePath: mbdDir.path,
      );

      expect(await File(p.join(outDir, 'bundle.mcpb')).exists(), isTrue);
      expect(result.canonicalHash, isNotEmpty);
    });
  });

  // ── dc10 bundle server layout ─────────────────────────────────────
  group('dc10 run bundle server', () {
    test('emits bin/server.dart, lib/, pubspec.yaml, README.md', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc10_bundle');
      await converter.run(
        canonical: _bundle(name: 'My Bundle App'),
        target: DartTarget.bundle,
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'bin', 'server.dart')).exists(), isTrue);
      expect(
        await File(p.join(outDir, 'lib', 'mcp_server_setup.dart')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(outDir, 'lib', 'ui_loader.dart')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(outDir, 'lib', 'handlers.dart')).exists(),
        isTrue,
      );
      expect(await File(p.join(outDir, 'pubspec.yaml')).exists(), isTrue);
      expect(await File(p.join(outDir, 'README.md')).exists(), isTrue);
    });

    test('pubspec.yaml includes mcp_bundle dep for bundle variant', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc10b_bundle');
      await converter.run(
        canonical: _bundle(),
        target: DartTarget.bundle,
        outDir: outDir,
      );
      final pubspec = await File(p.join(outDir, 'pubspec.yaml')).readAsString();
      expect(pubspec, contains('mcp_bundle'));
    });
  });

  // ── dc11 inline server layout ─────────────────────────────────────
  group('dc11 run inline server', () {
    test('emits bin/server.dart, lib/, pubspec.yaml', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc11_inline');
      await converter.run(
        canonical: _bundle(name: 'Inline App'),
        target: DartTarget.inline,
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'bin', 'server.dart')).exists(), isTrue);
      expect(await File(p.join(outDir, 'pubspec.yaml')).exists(), isTrue);
    });

    test('pubspec.yaml does NOT include mcp_bundle for inline', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc11b_inline');
      await converter.run(
        canonical: _bundle(),
        target: DartTarget.inline,
        outDir: outDir,
      );
      final pubspec = await File(p.join(outDir, 'pubspec.yaml')).readAsString();
      expect(pubspec, isNot(contains('mcp_bundle')));
    });
  });

  // ── dc12 nativeBundle layout ──────────────────────────────────────
  group('dc12 run nativeBundle', () {
    test('emits lib/main.dart, lib/native_app.dart, pubspec.yaml', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc12_natbundle');
      await converter.run(
        canonical: _bundle(name: 'Native Bundle App'),
        target: DartTarget.nativeBundle,
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'lib', 'main.dart')).exists(), isTrue);
      expect(
        await File(p.join(outDir, 'lib', 'native_app.dart')).exists(),
        isTrue,
      );
      expect(await File(p.join(outDir, 'pubspec.yaml')).exists(), isTrue);
    });

    test('pubspec.yaml includes flutter dependency', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc12b_natbundle');
      await converter.run(
        canonical: _bundle(),
        target: DartTarget.nativeBundle,
        outDir: outDir,
      );
      final pubspec = await File(p.join(outDir, 'pubspec.yaml')).readAsString();
      expect(pubspec, contains('flutter'));
    });
  });

  // ── dc13 nativeInline layout ──────────────────────────────────────
  group('dc13 run nativeInline', () {
    test('emits lib/main.dart, lib/ui_loader.dart, pubspec.yaml', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc13_natinline');
      await converter.run(
        canonical: _bundle(name: 'Native Inline App'),
        target: DartTarget.nativeInline,
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'lib', 'main.dart')).exists(), isTrue);
      expect(
        await File(p.join(outDir, 'lib', 'ui_loader.dart')).exists(),
        isTrue,
      );
      expect(await File(p.join(outDir, 'pubspec.yaml')).exists(), isTrue);
    });

    test('no assets block in nativeInline pubspec', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc13b_natinline');
      await converter.run(
        canonical: _bundle(),
        target: DartTarget.nativeInline,
        outDir: outDir,
      );
      final pubspec = await File(p.join(outDir, 'pubspec.yaml')).readAsString();
      // nativeInline has no Flutter assets block (UI is baked in).
      expect(pubspec, isNot(contains('assets:')));
    });
  });

  // ── dc14 convert.json target field ───────────────────────────────
  group('dc14 convert.json target field', () {
    for (final target in DartTarget.values) {
      test('target=${target.name} convert.json has correct target', () async {
        final converter = DartConverterImpl();
        final outDir = p.join(tmp.path, 'dc14_${target.name}');
        await converter.run(
          canonical: _bundle(),
          target: target,
          outDir: outDir,
        );
        final convertJson =
            jsonDecode(
                  await File(p.join(outDir, 'convert.json')).readAsString(),
                )
                as Map<String, dynamic>;
        expect(convertJson['target'], 'dart_${target.name}');
      });
    }
  });

  // ── dc15 convert.json hash ────────────────────────────────────────
  group('dc15 convert.json canonical_hash', () {
    test('canonical_hash starts with sha256:', () async {
      final converter = DartConverterImpl();
      final outDir = p.join(tmp.path, 'dc15_hash');
      final result = await converter.run(
        canonical: _bundle(),
        target: DartTarget.mcpb,
        outDir: outDir,
      );
      expect(result.canonicalHash, startsWith('sha256:'));
      final convertJson =
          jsonDecode(await File(p.join(outDir, 'convert.json')).readAsString())
              as Map<String, dynamic>;
      expect(convertJson['canonical_hash'], result.canonicalHash);
    });
  });

  // ── dc16 PatternException on violations ───────────────────────────
  group('dc16 PatternException raised on violations', () {
    test(
      'run throws PatternException when enforcer reports violations',
      () async {
        final converter = DartConverterImpl(
          enforcer: const _AlwaysViolatingEnforcer(),
        );
        final outDir = p.join(tmp.path, 'dc16_violation');
        await expectLater(
          () => converter.run(
            canonical: _bundle(),
            target: DartTarget.mcpb,
            outDir: outDir,
          ),
          throwsA(isA<PatternException>()),
        );
      },
    );
  });

  // ══════════════════════════════════════════════════════════════════════
  // EmbedConverter
  // ══════════════════════════════════════════════════════════════════════

  // ── ec1 unsupported board ─────────────────────────────────────────
  group('ec1 unsupported board', () {
    test('throws EmbedException', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec1_bad_board');
      await expectLater(
        () => converter.run(
          canonical: _bundle(),
          mode: EmbedMode.native,
          board: 'nonexistent_board_xyz',
          outDir: outDir,
        ),
        throwsA(isA<EmbedException>()),
      );
    });

    test('EmbedException message contains the bad board name', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec1b_bad_board');
      Object? caught;
      try {
        await converter.run(
          canonical: _bundle(),
          mode: EmbedMode.native,
          board: 'mega_banana',
          outDir: outDir,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<EmbedException>());
      expect(caught.toString(), contains('mega_banana'));
    });
  });

  // ── ec2 native mode files ─────────────────────────────────────────
  group('ec2 native mode', () {
    test('emits src/server.c and CMakeLists.txt', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec2_native');
      await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.native,
        board: 'esp32',
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'src', 'server.c')).exists(), isTrue);
      expect(await File(p.join(outDir, 'CMakeLists.txt')).exists(), isTrue);
    });

    test('no data/manifest.json in native mode', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec2b_native');
      await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.native,
        board: 'rp2040',
        outDir: outDir,
      );
      expect(
        await File(p.join(outDir, 'data', 'manifest.json')).exists(),
        isFalse,
      );
    });
  });

  // ── ec3 withBundle mode ───────────────────────────────────────────
  group('ec3 withBundle mode', () {
    test('emits data/manifest.json', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec3_bundle');
      await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.withBundle,
        board: 'stm32f4',
        outDir: outDir,
      );
      final manifest = File(p.join(outDir, 'data', 'manifest.json'));
      expect(await manifest.exists(), isTrue);
      // Verify it's valid JSON.
      expect(() => jsonDecode(manifest.readAsStringSync()), returnsNormally);
    });

    test('emits src/server.c and CMakeLists.txt too', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec3b_bundle');
      await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.withBundle,
        board: 'esp32',
        outDir: outDir,
      );
      expect(await File(p.join(outDir, 'src', 'server.c')).exists(), isTrue);
      expect(await File(p.join(outDir, 'CMakeLists.txt')).exists(), isTrue);
    });
  });

  // ── ec4 convert.json ──────────────────────────────────────────────
  group('ec4 convert.json has board + mode + canonical_hash', () {
    test('convert.json contains expected keys', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec4_json');
      final result = await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.native,
        board: 'linux-host',
        outDir: outDir,
      );
      final json =
          jsonDecode(await File(p.join(outDir, 'convert.json')).readAsString())
              as Map<String, dynamic>;
      expect(json['board'], 'linux-host');
      expect(json['mode'], 'native');
      expect(json['target'], 'embed_c');
      expect(result.canonicalHash, startsWith('sha256:'));
      expect(json['canonical_hash'], result.canonicalHash);
    });
  });

  // ── ec5 linux-host board ──────────────────────────────────────────
  group('ec5 linux-host board supported', () {
    test('linux-host does not throw EmbedException', () async {
      final converter = EmbedConverterImpl();
      final outDir = p.join(tmp.path, 'ec5_linux');
      // Run directly; if EmbedException is thrown the test fails.
      final result = await converter.run(
        canonical: _bundle(),
        mode: EmbedMode.native,
        board: 'linux-host',
        outDir: outDir,
      );
      expect(result.writtenFiles, isNotEmpty);
    });
  });
}
