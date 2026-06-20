/// Register `studio.chat.send` — drops a user turn into the active
/// tab's chat (or a specific tab) and triggers the agent reply. The
/// chat-driving primitive for automated scenarios.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../../main/chrome_bridge.dart';

void registerChatTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
}) {
  boot.addTool(
    name: 'studio.chat.send',
    description:
        "Drop a user turn into the active tab's chat (or `tabKey` "
        'when provided) and trigger the agent reply — same code '
        "path as the user typing in the chat input. Returns ok "
        "after the reply turn lands (or ok with `waitedReply: false` "
        'when `await: false`). Used by scenario engines / external '
        "LLMs to script chat-driven flows. Required for any demo "
        'that shows the user "typing" a message.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'text': <String, dynamic>{
          'type': 'string',
          'description': 'Message body to inject as a user turn.',
        },
        'tabKey': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional target tab key (`home` or bundle path). '
              'Omitted → active tab.',
        },
        'await': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true (default), wait for the assistant reply '
              'before resolving. When false, the call returns as '
              'soon as the user turn is in the feed (fire and '
              'forget).',
        },
      },
      'required': <String>['text'],
    },
    handler: (args) async {
      final text = args['text'] as String?;
      if (text == null || text.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"text required"}'),
          ],
        );
      }
      final fn = bridge.sendChat;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"sendChat-not-wired"}',
            ),
          ],
        );
      }
      final waited = args['await'] as bool? ?? true;
      try {
        final result = await fn(
          tabKey: args['tabKey'] as String?,
          text: text,
          waitForReply: waited,
        );
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{'ok': true, ...result}),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': e.toString(),
              }),
            ),
          ],
        );
      }
    },
  );
}
