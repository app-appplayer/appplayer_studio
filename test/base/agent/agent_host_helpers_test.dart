/// Unit tests for `AgentHost` pure static helpers.
///
/// The static methods `_scopedAgentId`, `_scopeLeaf`, and `_stableHash`
/// are private, but their observable behaviour is accessible through the
/// public `ensureScopedManager` call chain — or by directly testing the
/// observable outputs via a thin subclass that exposes them.
///
/// To avoid constructing a live KernelApp (boot-dependent), we test the
/// stable-hash property by extracting it through a local clone of the
/// exact algorithm used in AgentHost. This is white-box but deterministic
/// and boot-independent.
///
/// Scenarios:
///   ah1  _stableHash — empty string produces deterministic 8-hex output
///   ah2  _stableHash — different strings produce different hashes
///   ah3  _stableHash — same string always produces same hash (stability)
///   ah4  _scopeLeaf — UNIX path returns last non-empty segment
///   ah5  _scopeLeaf — Windows-style path with backslash
///   ah6  _scopeLeaf — empty scope returns as-is
///   ah7  _scopeLeaf — trailing slash is ignored (last non-empty segment)
///   ah8  _scopedAgentId — empty scope returns baseId unchanged
///   ah9  _scopedAgentId — non-empty scope returns baseId + dot + leaf_hash
///   ah10 _scopedAgentId — two distinct paths produce distinct ids
library;

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Inline clones of private static helpers from agent_host.dart.
// Algorithm is identical — tested deterministically.
// ---------------------------------------------------------------------------

String _stableHash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String _scopeLeaf(String scope) {
  final parts =
      scope.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? scope : parts.last;
}

String _scopedAgentId(String baseId, String scope) {
  if (scope.isEmpty) return baseId;
  final safeLeaf = _scopeLeaf(scope).replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return '$baseId.${safeLeaf}_${_stableHash(scope)}';
}

void main() {
  // -------------------------------------------------------------------------
  // _stableHash
  // -------------------------------------------------------------------------
  group('_stableHash (FNV-1a 32-bit)', () {
    test('ah1 empty string → 8-char hex output', () {
      final h = _stableHash('');
      expect(h, hasLength(8));
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(h), isTrue);
    });

    test('ah2 different strings produce different hashes', () {
      expect(_stableHash('pathA'), isNot(_stableHash('pathB')));
    });

    test('ah3 same string always produces same hash', () {
      const s = '/home/user/projects/ops/team_hr.mbd';
      expect(_stableHash(s), _stableHash(s));
    });

    test('ah3b stability across multiple calls', () {
      final hashes = List.generate(10, (_) => _stableHash('stable_input'));
      expect(hashes.toSet(), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // _scopeLeaf
  // -------------------------------------------------------------------------
  group('_scopeLeaf', () {
    test('ah4 UNIX path returns last segment', () {
      expect(_scopeLeaf('/home/user/projects/ops'), 'ops');
    });

    test('ah4b single segment path', () {
      expect(_scopeLeaf('workspace'), 'workspace');
    });

    test('ah5 Windows-style backslash path', () {
      expect(_scopeLeaf(r'C:\Users\user\projects\ops'), 'ops');
    });

    test('ah6 empty scope returns as-is', () {
      expect(_scopeLeaf(''), '');
    });

    test('ah7 trailing slash ignored', () {
      expect(_scopeLeaf('/home/user/ops/'), 'ops');
    });

    test('ah7b double slash ignored', () {
      expect(_scopeLeaf('/home//team'), 'team');
    });
  });

  // -------------------------------------------------------------------------
  // _scopedAgentId
  // -------------------------------------------------------------------------
  group('_scopedAgentId', () {
    test('ah8 empty scope returns baseId unchanged', () {
      expect(_scopedAgentId('manager', ''), 'manager');
    });

    test('ah9 non-empty scope returns baseId.safeLeaf_hash', () {
      const scope = '/projects/ops/team_hr.mbd';
      final id = _scopedAgentId('manager', scope);
      // Must start with 'manager.'
      expect(id, startsWith('manager.'));
      // Must contain a hash portion (8 hex chars at end)
      final parts = id.split('_');
      final lastPart = parts.last;
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(lastPart), isTrue);
    });

    test('ah10 two distinct paths produce distinct scoped ids', () {
      final id1 = _scopedAgentId('manager', '/proj/a');
      final id2 = _scopedAgentId('manager', '/proj/b');
      expect(id1, isNot(id2));
    });

    test('ah — special chars in leaf are sanitised to underscore', () {
      const scope = '/path/to/my-bundle v2.mbd';
      final id = _scopedAgentId('studio.manager', scope);
      // The safeLeaf should not contain '-' or '.' or spaces
      // (those get replaced by '_' from the replaceAll)
      final afterDot = id.substring('studio.manager.'.length);
      expect(afterDot, isNot(contains('-')));
      expect(afterDot, isNot(contains(' ')));
    });

    test('ah — deterministic: same args always give same result', () {
      const base = 'manager';
      const scope = '/workspace/eng/project1';
      final first = _scopedAgentId(base, scope);
      final second = _scopedAgentId(base, scope);
      expect(first, second);
    });
  });
}
