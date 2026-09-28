/// Masks secret values in tool-call arguments before they are shown or
/// returned anywhere (the dispatch log tool, the Ops audit view).
///
/// Two rules:
///   * A field whose name marks it as secret (`token`, `password`,
///     `passphrase`, `apiKey`, `secret`, `credential`, `authorization`,
///     `privateKey`, `sealed`) has its value masked, whatever its type.
///   * A tool that stores credentials (`secret.*`, `*credential*`) has every
///     string masked except the fields that only name the entry.
library;

/// What a masked value reads as.
const String kRedacted = '[redacted]';

final RegExp _secretField = RegExp(
  r'secret|token|password|passphrase|api[_-]?key|credential|authorization|'
  r'private[_-]?key|sealed',
  caseSensitive: false,
);

final RegExp _credentialTool = RegExp(
  r'(^|\.)secret\.|credential',
  caseSensitive: false,
);

/// Fields a credential tool may show — they name the entry, not its value.
const Set<String> _namingFields = <String>{'id', 'ref', 'platform', 'prefix'};

/// [args] of a call to [tool] with every secret value replaced by
/// [kRedacted]. The input is not modified.
Object? redactToolArgs(String tool, Object? args) =>
    _redact(args, maskAllStrings: _credentialTool.hasMatch(tool));

Object? _redact(Object? node, {required bool maskAllStrings, String? field}) {
  if (field != null && _secretField.hasMatch(field)) return kRedacted;
  if (node is Map) {
    return <String, Object?>{
      for (final e in node.entries)
        '${e.key}': _redact(
          e.value,
          maskAllStrings: maskAllStrings,
          field: '${e.key}',
        ),
    };
  }
  if (node is List) {
    return <Object?>[
      for (final v in node) _redact(v, maskAllStrings: maskAllStrings),
    ];
  }
  if (node is String && maskAllStrings && !_namingFields.contains(field)) {
    return kRedacted;
  }
  return node;
}
