/// Placeholder LLM adapter — the universal host's chat is inactive
/// until a bundle activates and supplies its own adapter. Other studio
/// hosts that need to defer LLM wiring (e.g. boot before bundle
/// activation) can reuse this shape via [StudioApp.buildLlmAdapter].
library;

import 'chat_turn.dart';

class NoopLlm {
  const NoopLlm();

  /// Returns a single system note. Replaced by the bundle's adapter
  /// once activation completes; until then the chat panel surfaces this
  /// turn so the user sees a clear "no bundle active" signal.
  Future<ChatTurn> send(String input) async =>
      ChatTurn(role: 'assistant', text: 'No active bundle.');
}
