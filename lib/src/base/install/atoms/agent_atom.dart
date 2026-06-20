/// Cross-agent dispatch atom — `host.agent.*`. Lets a JS tool ask a
/// host-registered agent (built-in `studio.*` agents or other bundles'
/// agents) and read the reply text. The bundle must list `'agent'` in
/// `requires.builtinAtoms`.
///
/// The atom delegates to [AgentHost.shared] — bundles activated under
/// a host that has not yet booted FlowBrain (e.g. headless tests
/// without the agent stack) get a clear "AgentHost not initialised"
/// error rather than a silent no-op.
library;

import 'package:brain_kernel/brain_kernel.dart' as fb;

import '../../agent/agent_host.dart';
import 'atom_category.dart';

class AgentAtom extends AtomCategory {
  /// Optional override — pass null to use [AgentHost.shared] (the
  /// production path). Test harnesses that boot a custom AgentHost
  /// can inject it.
  AgentAtom({AgentHost? host}) : _hostOverride = host;

  final AgentHost? _hostOverride;

  AgentHost? get _host => _hostOverride ?? AgentHost.shared;

  @override
  String get key => 'agent';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'invoke',
      description: 'Ask an agent (agentId, message) → reply text.',
    ),
    AtomVerb('list', description: 'List registered agent ids.'),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    final host = _host;
    if (host == null) {
      throw StateError('AgentHost not initialised');
    }
    switch (verb) {
      case 'invoke':
        if (args.length < 2) {
          throw ArgumentError('invoke requires (agentId, message)');
        }
        final agentId = args[0];
        final message = args[1];
        if (agentId is! String || agentId.isEmpty) {
          throw ArgumentError('agentId must be a non-empty String');
        }
        if (message is! String) {
          throw ArgumentError('message must be a String');
        }
        final fb.AgentReply reply = await host.askAgent(agentId, message);
        return <String, dynamic>{
          'agentId': agentId,
          'content': reply.content,
          if (reply.finishReason != null) 'finishReason': reply.finishReason,
        };
      case 'list':
        return host.profiles.map((p) => p.id).toList();
      default:
        throw ArgumentError('unknown verb: agent.$verb');
    }
  }
}
