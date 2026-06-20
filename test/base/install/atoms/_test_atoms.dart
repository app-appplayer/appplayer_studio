import 'package:appplayer_studio/base.dart';

/// Trivial atom for bridge round-trip tests — no I/O, no scope.
class EchoAtom extends AtomCategory {
  @override
  String get key => 'echo';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb('shout', description: 'Uppercases the input string.'),
    AtomVerb('add', description: 'Sums two numbers.'),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'shout':
        final s = args[0] as String;
        return s.toUpperCase();
      case 'add':
        final a = args[0] as num;
        final b = args[1] as num;
        return a + b;
      default:
        throw ArgumentError('unknown verb: echo.$verb');
    }
  }
}
