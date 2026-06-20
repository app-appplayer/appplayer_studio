/// UI feedback atom — `host.ui.*`. Bundles reach into the host's
/// chrome to show a toast / dialog / prompt. The atom delegates to a
/// [ChromeBridge] — when a slot is unset (e.g. tests, headless boots)
/// the call falls back to a clear no-op result rather than crashing
/// the JS caller.
///
/// Bundles must list `'ui'` in `requires.builtinAtoms`.
library;

import '../../main/chrome_bridge.dart';
import 'atom_category.dart';

class UiAtom extends AtomCategory {
  UiAtom({required this.bridge});

  final ChromeBridge bridge;

  @override
  String get key => 'ui';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'notify',
      description:
          'Show a transient toast. (message, [severity]) → '
          '{shown: bool}.',
    ),
    AtomVerb(
      'dialog',
      description:
          'Show a modal info dialog. (title, body) → {dismissed: bool}.',
    ),
    AtomVerb(
      'prompt',
      description:
          'Show a yes/no confirmation. (question, [options]) → '
          '{choice: int} (-1 on dismiss / unwired).',
    ),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'notify':
        if (args.isEmpty) {
          throw ArgumentError('notify requires (message, [severity])');
        }
        final message = args[0];
        if (message is! String) {
          throw ArgumentError('message must be a String');
        }
        final severity =
            args.length > 1 && args[1] is String ? args[1] as String : null;
        final slot = bridge.notify;
        if (slot == null) {
          return <String, dynamic>{'shown': false, 'reason': 'no host slot'};
        }
        slot(message, severity: severity);
        return <String, dynamic>{'shown': true};
      case 'dialog':
        if (args.length < 2) {
          throw ArgumentError('dialog requires (title, body)');
        }
        final title = args[0];
        final body = args[1];
        if (title is! String || body is! String) {
          throw ArgumentError('title and body must be Strings');
        }
        final slot = bridge.dialog;
        if (slot == null) {
          return <String, dynamic>{
            'dismissed': false,
            'reason': 'no host slot',
          };
        }
        final dismissed = await slot(title: title, body: body);
        return <String, dynamic>{'dismissed': dismissed};
      case 'prompt':
        if (args.isEmpty) {
          throw ArgumentError('prompt requires (question, [options])');
        }
        final question = args[0];
        if (question is! String) {
          throw ArgumentError('question must be a String');
        }
        List<String>? options;
        if (args.length > 1 && args[1] is List) {
          options = (args[1] as List).whereType<String>().toList();
        }
        final slot = bridge.prompt;
        if (slot == null) {
          return <String, dynamic>{'choice': -1, 'reason': 'no host slot'};
        }
        final choice = await slot(question: question, options: options);
        return <String, dynamic>{'choice': choice};
      default:
        throw ArgumentError('unknown verb: ui.$verb');
    }
  }
}
