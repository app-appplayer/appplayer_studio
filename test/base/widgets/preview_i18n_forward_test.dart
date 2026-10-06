import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:brain_kernel/brain_kernel.dart' show CanonicalChange;

import 'package:appplayer_studio/base.dart'
    show CanonicalUiViewAdapter, WorkspaceCanonical;

/// Page, dashboard and component previews wrap their target in a synthetic
/// application. The runtime loads `i18n` (spec §12) from the application
/// only, so a wrapper that drops it renders every `{{i18n.key}}` as missing.
class _FakeCanonical implements WorkspaceCanonical {
  final StreamController<CanonicalChange> _changes =
      StreamController<CanonicalChange>.broadcast(sync: true);

  @override
  Stream<CanonicalChange> get changes => _changes.stream;

  @override
  Map<String, dynamic> get currentJson => <String, dynamic>{
    'ui': <String, dynamic>{
      'type': 'application',
      'initialRoute': '/home',
      'routes': <String, dynamic>{'/home': 'ui://pages/home'},
      'i18n': _i18n,
      'dashboard': <String, dynamic>{
        'content': <String, dynamic>{'type': 'text', 'content': 'd'},
      },
      'templates': <String, dynamic>{
        'card': <String, dynamic>{
          'content': <String, dynamic>{'type': 'text', 'content': 'c'},
        },
      },
      'pages': <String, dynamic>{
        'home': <String, dynamic>{
          'type': 'page',
          'content': <String, dynamic>{
            'type': 'text',
            'content': '{{i18n.greet}}',
          },
        },
      },
    },
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const Map<String, dynamic> _i18n = <String, dynamic>{
  'defaultLocale': 'en',
  'locales': <String>['en', 'ko'],
  'text': <String, dynamic>{
    'en': <String, dynamic>{'greet': 'Hello'},
    'ko': <String, dynamic>{'greet': 'Annyeong'},
  },
};

void main() {
  final adapter = CanonicalUiViewAdapter(_FakeCanonical());

  for (final target in <String>[
    'mcp-ui:app',
    'mcp-ui:page/home',
    'mcp-ui:dashboard',
    'mcp-ui:component/card',
  ]) {
    test('$target carries the application i18n block', () async {
      final snap = await adapter.fetch(target);
      expect(snap.data['i18n'], _i18n);
    });
  }
}
