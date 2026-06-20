/// VibeChatController — chat panel state + agent dispatch routing.
/// Generic over agent ids: hosts pass [agents] (e.g. derived from a
/// 7-agent catalog) and [sendForAgent] callback wiring to their
/// AgentHost. Manager is the default channel.
library;

import 'package:flutter/foundation.dart';

import 'chat_turn.dart';

class VibeChatController extends ChangeNotifier {
  VibeChatController({
    required this.send,
    this.sendForAgent,
    this.agents = const <VibeChatAgentEntry>[],
    this.onTurnPersisted,
    this.onClearLog,
    this.onRemoveTurn,
  });

  /// Default send path — used when the selected agent is the manager
  /// (the chat panel's default channel). Wraps the host's existing
  /// single-LLM + tool-dispatch flow.
  final Future<ChatTurn> Function(String userInput) send;

  /// Per-agent send path — invoked when the selected agent is not the
  /// manager. The host wires this to `AgentHost.askAgent(agentId, text)`
  /// + reply→ChatTurn conversion. Null when no agent host is booted.
  final Future<ChatTurn> Function(String agentId, String userInput)?
  sendForAgent;

  /// Available agents the dropdown can switch to. Empty list = chip is
  /// hidden (no agent host booted).
  final List<VibeChatAgentEntry> agents;

  /// Agent currently bound to the chat panel. Default = manager. Setter
  /// notifies listeners so the dropdown chip rebuilds.
  String _selectedAgentId = 'manager';
  String get selectedAgentId => _selectedAgentId;
  set selectedAgentId(String id) {
    if (_selectedAgentId == id) return;
    _selectedAgentId = id;
    notifyListeners();
  }

  /// Called after every turn (user prompt + assistant reply) is added
  /// to the feed. Hosts use this to append to chat.jsonl on disk so the
  /// conversation survives app restarts. Failures should be swallowed.
  Future<void> Function(ChatTurn turn)? onTurnPersisted;

  /// Called when [clear] runs so the host can wipe the on-disk
  /// chat.jsonl alongside the in-memory turns.
  Future<void> Function()? onClearLog;

  /// Called when [removeTurn] runs so the host can drop a single
  /// turn from chat.jsonl.
  Future<void> Function(ChatTurn turn)? onRemoveTurn;

  final List<ChatTurn> _turns = <ChatTurn>[];
  bool _busy = false;

  List<ChatTurn> get turns => List.unmodifiable(_turns);
  bool get busy => _busy;

  /// Replace the current feed with [turns]. Used by the host to
  /// rehydrate the panel from a project's chat.jsonl on open.
  void seed(Iterable<ChatTurn> turns) {
    _turns
      ..clear()
      ..addAll(turns);
    notifyListeners();
  }

  /// Drop every turn from the feed AND fire [onClearLog] so the
  /// host can wipe its persisted chat log.
  Future<void> clear() async {
    _turns.clear();
    notifyListeners();
    final cb = onClearLog;
    if (cb != null) {
      try {
        await cb();
      } catch (_) {
        /* swallowed — best effort */
      }
    }
  }

  /// Remove a single turn (identity comparison).
  Future<void> removeTurn(ChatTurn turn) async {
    final removed = _turns.remove(turn);
    if (!removed) return;
    notifyListeners();
    final cb = onRemoveTurn;
    if (cb != null) {
      try {
        await cb(turn);
      } catch (_) {
        /* swallow — best effort */
      }
    }
  }

  /// Append a single turn (e.g. an `assistant.patch` card emitted from
  /// inside an LLM tool-use loop).
  void appendTurn(ChatTurn turn) {
    _turns.add(turn);
    notifyListeners();
    onTurnPersisted?.call(turn);
  }

  Future<void> ask(String text) async {
    if (text.trim().isEmpty || _busy) return;
    _busy = true;
    final userTurn = ChatTurn(role: 'user', text: text);
    _turns.add(userTurn);
    notifyListeners();
    onTurnPersisted?.call(userTurn);
    try {
      final useAgentPath =
          _selectedAgentId != 'manager' && sendForAgent != null;
      final reply =
          useAgentPath
              ? await sendForAgent!(_selectedAgentId, text)
              : await send(text);
      _turns.add(reply);
      onTurnPersisted?.call(reply);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}

/// Single entry the chat dropdown shows — agent id + display name.
/// Hosts derive this from their agent catalog (e.g. `kVibeAgentProfiles`).
/// `id` matches `VibeAgentProfile.id`.
class VibeChatAgentEntry {
  const VibeChatAgentEntry({
    required this.id,
    required this.displayName,
    this.modelId,
  });
  final String id;
  final String displayName;
  final String? modelId;
}
