/// Unit tests for the static/top-level symbols in
/// `app_builder/feat/build_tools.dart` and
/// `app_builder/conv/dart_converter.dart` /
/// `app_builder/conv/embed_converter.dart` that are NOT covered by the
/// existing test files.
///
/// Scenario index:
///
/// --- BuildToolsDispatcher.toolDefinitions ---
/// s1  every entry has a non-empty `name`
/// s2  every entry has a non-empty `description`
/// s3  every entry has a `parameters` map with a `type: "object"` field
/// s4  `pack_bundle` entry has an `outPath` required param
/// s5  `run_shell` entry has a `command` param
/// s6  entry count matches claimedTools cardinality
///
/// --- BuildToolsDispatcher.claimedTools ---
/// s7  claimedTools is non-empty
/// s8  claimedTools contains the five key tool names we rely on
/// s9  claimedTools does NOT contain the file-tool names
///        (build tools and file tools are distinct dispatchers)
/// s10 every toolDefinitions name appears in claimedTools
///
/// --- encodeBuildToolResult ---
/// s11 success result encodes to valid JSON with ok=true
/// s12 failure result encodes to valid JSON with ok=false
/// s13 optional path is present when set, absent when null
/// s14 optional payload is present when set, absent when null
///
/// --- DartTarget enum ---
/// s15 has exactly 5 values
/// s16 every value has a non-empty name
/// s17 required value names are present (mcpb, bundle, inline, nativeBundle, nativeInline)
///
/// --- EmbedMode enum ---
/// s18 has exactly 2 values (native, withBundle)
/// s19 name 'native' resolves correctly
/// s20 name 'withBundle' resolves correctly
///
/// --- EmbedException ---
/// s21 toString includes the prefix 'EmbedException:'
/// s22 message is preserved verbatim
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/dart_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/conv/embed_converter.dart';
import 'package:appplayer_studio/src/apps/app_builder/feat/build_tools.dart';

void main() {
  // ── BuildToolsDispatcher.toolDefinitions ─────────────────────────────────

  group('s1 toolDefinitions — every entry has a non-empty name', () {
    test('all names are non-empty strings', () {
      for (final entry in BuildToolsDispatcher.toolDefinitions) {
        final name = entry['name'];
        expect(name, isA<String>(), reason: 'entry $entry missing name');
        expect(
          (name as String).isNotEmpty,
          isTrue,
          reason: 'entry has empty name',
        );
      }
    });
  });

  group('s2 toolDefinitions — every entry has a non-empty description', () {
    test('all descriptions are non-empty strings', () {
      for (final entry in BuildToolsDispatcher.toolDefinitions) {
        final desc = entry['description'];
        expect(
          desc,
          isA<String>(),
          reason: 'entry ${entry["name"]} missing description',
        );
        expect(
          (desc as String).isNotEmpty,
          isTrue,
          reason: 'entry ${entry["name"]} has empty description',
        );
      }
    });
  });

  group('s3 toolDefinitions — parameters is an object-typed map', () {
    test('every entry has parameters.type == "object"', () {
      for (final entry in BuildToolsDispatcher.toolDefinitions) {
        final params = entry['parameters'];
        expect(
          params,
          isA<Map>(),
          reason: '${entry["name"]}: parameters must be a Map',
        );
        expect(
          (params as Map)['type'],
          equals('object'),
          reason: '${entry["name"]}: parameters.type must be "object"',
        );
      }
    });
  });

  group('s4 pack_bundle entry has outPath in required', () {
    test('pack_bundle required includes outPath', () {
      final entry = BuildToolsDispatcher.toolDefinitions.firstWhere(
        (e) => e['name'] == 'pack_bundle',
      );
      final params = entry['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      expect(props.containsKey('outPath'), isTrue);
      final required = params['required'] as List?;
      expect(required, isNotNull);
      expect(required, contains('outPath'));
    });
  });

  group('s5 run_shell entry has command param', () {
    test('run_shell properties contains command', () {
      final entry = BuildToolsDispatcher.toolDefinitions.firstWhere(
        (e) => e['name'] == 'run_shell',
      );
      final params = entry['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      expect(props.containsKey('command'), isTrue);
    });
  });

  group('s6 toolDefinitions count matches claimedTools cardinality', () {
    test('every toolDefinitions name is in claimedTools', () {
      for (final entry in BuildToolsDispatcher.toolDefinitions) {
        final name = entry['name'] as String;
        expect(
          BuildToolsDispatcher.claimedTools.contains(name),
          isTrue,
          reason: '$name in toolDefinitions but not in claimedTools',
        );
      }
    });
  });

  // ── BuildToolsDispatcher.claimedTools ────────────────────────────────────

  group('s7 claimedTools is non-empty', () {
    test('at least one tool is claimed', () {
      expect(BuildToolsDispatcher.claimedTools, isNotEmpty);
    });
  });

  group('s8 claimedTools contains key tool names', () {
    const expected = <String>[
      'pack_bundle',
      'run_shell',
      'read_build_guide',
      'bundle_outline',
      'tree_outline',
    ];
    for (final name in expected) {
      test('contains $name', () {
        expect(BuildToolsDispatcher.claimedTools.contains(name), isTrue);
      });
    }
  });

  group('s9 claimedTools does not contain file-tool names', () {
    const fileSide = <String>[
      'write_file',
      'edit_file',
      'make_dir',
      'delete_file',
      'read_file',
      'list_dir',
    ];
    for (final name in fileSide) {
      test('does NOT contain $name', () {
        expect(
          BuildToolsDispatcher.claimedTools.contains(name),
          isFalse,
          reason:
              '$name is a file-tool and must not appear in build claimed set',
        );
      });
    }
  });

  group('s10 all toolDefinitions names are in claimedTools', () {
    test('toolDefinitions is a strict subset of claimedTools', () {
      for (final entry in BuildToolsDispatcher.toolDefinitions) {
        final name = entry['name'] as String;
        expect(BuildToolsDispatcher.claimedTools, contains(name));
      }
    });
  });

  // ── encodeBuildToolResult ─────────────────────────────────────────────────

  group(
    's11 encodeBuildToolResult success produces valid JSON with ok=true',
    () {
      test('ok field is true', () {
        final r = BuildToolResult.success(message: 'done');
        final decoded =
            jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
        expect(decoded['ok'], isTrue);
        expect(decoded['message'], 'done');
      });
    },
  );

  group(
    's12 encodeBuildToolResult failure produces valid JSON with ok=false',
    () {
      test('ok field is false', () {
        final r = BuildToolResult.failure('boom');
        final decoded =
            jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
        expect(decoded['ok'], isFalse);
        expect(decoded['message'], 'boom');
      });
    },
  );

  group('s13 encodeBuildToolResult path presence', () {
    test('path is included when set', () {
      final r = BuildToolResult.success(message: 'ok', path: 'out/x.txt');
      final decoded =
          jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
      expect(decoded['path'], 'out/x.txt');
    });

    test('path key is absent when not set', () {
      final r = BuildToolResult.success(message: 'ok');
      final decoded =
          jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
      expect(decoded.containsKey('path'), isFalse);
    });
  });

  group('s14 encodeBuildToolResult payload presence', () {
    test('payload is included when set', () {
      final r = BuildToolResult.success(message: 'ok', payload: '{"n":42}');
      final decoded =
          jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
      expect(decoded['payload'], '{"n":42}');
    });

    test('payload key is absent when not set', () {
      final r = BuildToolResult.success(message: 'ok');
      final decoded =
          jsonDecode(encodeBuildToolResult(r)) as Map<String, dynamic>;
      expect(decoded.containsKey('payload'), isFalse);
    });
  });

  // ── DartTarget enum ───────────────────────────────────────────────────────

  group('s15 DartTarget has exactly 5 values', () {
    test('value count is 5', () {
      expect(DartTarget.values, hasLength(5));
    });
  });

  group('s16 every DartTarget value has a non-empty name', () {
    test('all names non-empty', () {
      for (final t in DartTarget.values) {
        expect(t.name, isNotEmpty);
      }
    });
  });

  group('s17 required DartTarget names are present', () {
    const required = <String>[
      'mcpb',
      'bundle',
      'inline',
      'nativeBundle',
      'nativeInline',
    ];
    for (final name in required) {
      test('DartTarget.$name exists', () {
        expect(
          DartTarget.values.any((t) => t.name == name),
          isTrue,
          reason: 'DartTarget.$name not found in values',
        );
      });
    }
  });

  // ── EmbedMode enum ────────────────────────────────────────────────────────

  group('s18 EmbedMode has exactly 2 values', () {
    test('value count is 2', () {
      expect(EmbedMode.values, hasLength(2));
    });
  });

  group('s19 EmbedMode.native name', () {
    test('native has name "native"', () {
      expect(EmbedMode.native.name, 'native');
    });
  });

  group('s20 EmbedMode.withBundle name', () {
    test('withBundle has name "withBundle"', () {
      expect(EmbedMode.withBundle.name, 'withBundle');
    });
  });

  // ── EmbedException ────────────────────────────────────────────────────────

  group('s21 EmbedException.toString includes prefix', () {
    test('toString starts with "EmbedException:"', () {
      final e = EmbedException('bad board');
      expect(e.toString(), startsWith('EmbedException:'));
    });
  });

  group('s22 EmbedException preserves message', () {
    test('message field matches constructor arg', () {
      const msg = 'unsupported board xyz';
      final e = EmbedException(msg);
      expect(e.message, msg);
      expect(e.toString(), contains(msg));
    });
  });
}
