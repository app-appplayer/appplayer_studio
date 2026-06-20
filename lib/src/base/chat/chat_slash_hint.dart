/// Composer slash command hint surfaced as a tappable chip in the
/// chat panel. Authored by the host (universal studio = minimal set,
/// activated domain bundles append their own from
/// `manifest.chat.slashCommands[]`).
///
/// Two flavours:
///   * TEMPLATE chip — [tool] is null. The chip inserts
///     `command + template` into the input so the user (or downstream
///     agent) can finish the prompt; `template` ends with a space
///     when the command expects an arg so the caret lands ready.
///   * DIRECT-DISPATCH chip — [tool] is set. Submitting the chip
///     fires the bound tool with [arguments] (defaults to empty),
///     bypassing the LLM. The host owns dispatch (resolves namespace
///     → MCP callTool); panels just signal the selection.
library;

class ChatSlashHint {
  const ChatSlashHint(
    this.command, [
    this.template,
    this.description,
    this.tool,
    this.arguments,
  ]);
  final String command;
  final String? template;

  /// Optional one-liner shown in tooltips / autocomplete preview. UI
  /// today doesn't render it; future visibility work picks it up.
  final String? description;

  /// When non-null, the chip is a direct-dispatch entry. Bare tool
  /// name (no `<bundleNs>.` prefix) — the host resolves the activated
  /// bundle's namespace at dispatch time so the same name a chip uses
  /// is the same name an MCP-driving LLM would call.
  final String? tool;

  /// Pre-filled arguments passed to [tool] on dispatch. Stored as a
  /// JSON-serialisable map. Empty / null = no args.
  final Map<String, dynamic>? arguments;

  /// True for direct-dispatch chips — the host should call the bound
  /// tool instead of inserting [template] into the composer.
  bool get isDirectDispatch => tool != null && tool!.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'command': command,
    if (template != null) 'template': template,
    if (description != null) 'description': description,
    if (tool != null) 'tool': tool,
    if (arguments != null) 'arguments': arguments,
  };

  factory ChatSlashHint.fromJson(Map<String, dynamic> json) {
    final args = json['arguments'];
    return ChatSlashHint(
      json['command'] as String,
      json['template'] as String?,
      json['description'] as String?,
      json['tool'] as String?,
      args is Map ? Map<String, dynamic>.from(args) : null,
    );
  }
}
