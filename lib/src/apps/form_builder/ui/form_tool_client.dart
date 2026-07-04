/// In-process client for the host `form.*` capability — the UI's ONLY path
/// to the engine (button = tool, 1:1; no engine import, no side logic).
library;

import 'dart:convert' show jsonDecode;

import 'package:appplayer_studio/base.dart' show BuiltinToolRegistry;
import 'package:appplayer_studio/builtin_api.dart' as mk show KernelTextContent;

class FormToolException implements Exception {
  const FormToolException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Call a host tool and decode its JSON text payload. Throws
/// [FormToolException] on the capability's `{ok:false, code, error}`
/// envelope so pages surface clean messages.
Future<Map<String, dynamic>> callFormTool(
  BuiltinToolRegistry server,
  String name,
  Map<String, dynamic> args,
) async {
  final result = await server.callTool(name, args);
  final text =
      result.content
          .whereType<mk.KernelTextContent>()
          .map((c) => c.text)
          .join();
  final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  final map =
      decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{'value': decoded};
  if (result.isError == true) {
    throw FormToolException(
      (map['code'] as String?) ?? 'form.error',
      (map['error'] as String?) ?? text,
    );
  }
  return map;
}
