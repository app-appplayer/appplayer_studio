/// The state path a two-way property writes back to.
///
/// A two-way slot (`resizable.width`, `pdfViewer.page`, `popover.open`, …) is
/// declared `T | binding`, and the schema accepts both `"{{a.b}}"` and the
/// bare `"a.b"` for the binding form. Reading such a property as `String?`
/// throws the moment an author writes the literal the schema also allows, and
/// passing the raw `"{{a.b}}"` to `setValue` writes to a key literally named
/// `{{a.b}}` — so the drag persists nowhere while the read comes from `a.b`.
///
/// Returns null when [raw] is a literal, or when it is an expression rather
/// than a plain path: `{{a + 1}}` has no single target to write back to.
String? twoWayPath(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  final inner = trimmed.startsWith('{{') && trimmed.endsWith('}}')
      ? trimmed.substring(2, trimmed.length - 2).trim()
      : trimmed;
  return _path.hasMatch(inner) ? inner : null;
}

/// Mirrors the schema's own binding pattern for two-way slots.
final RegExp _path = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_.\[\]]*$');
