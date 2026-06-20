/// Unit coverage for `resolveIconName` — the public icon-name resolver
/// exported from `vbu_widgets.dart`. Tests cover known names, the
/// `icons.` prefix stripping, unknown names returning the fallback,
/// non-string input returning the fallback, and the IconData passthrough.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  group('resolveIconName', () {
    test('known name returns the correct IconData', () {
      expect(resolveIconName('home'), Icons.home);
      expect(resolveIconName('settings'), Icons.settings);
      expect(resolveIconName('add'), Icons.add);
      expect(resolveIconName('close'), Icons.close);
    });

    test('strips icons. prefix before lookup', () {
      expect(resolveIconName('icons.home'), Icons.home);
      expect(resolveIconName('icons.settings'), Icons.settings);
    });

    test('unknown name returns the fallback', () {
      expect(resolveIconName('totally_unknown_icon_xyz'), Icons.circle);
    });

    test('custom fallback is returned for unknown name', () {
      expect(
        resolveIconName('totally_unknown', fallback: Icons.error),
        Icons.error,
      );
    });

    test('null input returns fallback', () {
      expect(resolveIconName(null), Icons.circle);
    });

    test('non-string non-IconData input returns fallback', () {
      expect(resolveIconName(42), Icons.circle);
      expect(resolveIconName(<String>[]), Icons.circle);
    });

    test('IconData passthrough (already-resolved icon returns itself)', () {
      expect(resolveIconName(Icons.star), Icons.star);
    });

    test('icons. prefix with unknown suffix falls back', () {
      expect(resolveIconName('icons.nonexistent_xyz'), Icons.circle);
    });

    test('all registered names in the known map resolve non-null', () {
      // Spot-check a representative subset of the icon table.
      const knownNames = <String>[
        'home',
        'home_outlined',
        'add',
        'close',
        'check',
        'delete',
        'edit',
        'folder',
        'folder_open',
        'settings',
        'info',
        'warning',
        'error',
        'search',
        'refresh',
        'play_arrow',
        'stop',
        'pause',
        'chevron_left',
        'chevron_right',
        'expand_more',
        'expand_less',
        'more_vert',
        'more_horiz',
        'extension',
        'construction',
        'star',
        'history',
        'send',
        'copy',
      ];
      for (final name in knownNames) {
        final result = resolveIconName(name);
        expect(
          result,
          isNot(Icons.circle),
          reason: '"$name" should resolve to its icon, not the fallback',
        );
      }
    });
  });
}
