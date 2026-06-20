/// One turn in the LLM dialogue. Persisted by the host to disk
/// (`<projectPath>/chat.jsonl`) across sessions so users can resume.
///
/// `layer` is host-typed (`Object?`) — domain tools (vibe_app_builder
/// stores a `LayerId`, future tools may store a different enum) pass
/// whatever they like; the chat panel never inspects the type and
/// forwards it to host-supplied colour / label builders.
library;

class ChatTurn {
  ChatTurn({
    required this.role,
    required this.text,
    this.layer,
    this.fileCount,
    DateTime? at,
  }) : at = at ?? DateTime.now().toUtc();

  /// One of `user`, `assistant`, `assistant.patch`, `assistant.error`,
  /// `system`, `error` — drives the chat panel bubble style.
  final String role;
  final String text;

  /// Domain-typed layer reference for `assistant.patch` turns. Pass
  /// any value (enum, string, custom struct); the chat panel never
  /// inspects the type.
  final Object? layer;

  /// Optional metadata — number of files touched by an assistant
  /// patch.
  final int? fileCount;
  final DateTime at;
}
