/// Application-level error with structured code, message, and optional guidance.
class OpsError implements Exception {
  final String code;
  final String message;
  final String? detail;
  final String? suggestion;

  OpsError({
    required this.code,
    required this.message,
    this.detail,
    this.suggestion,
  });

  @override
  String toString() {
    final buffer = StringBuffer('OpsError[$code]: $message');
    if (detail != null) buffer.write('\n  Detail: $detail');
    if (suggestion != null) buffer.write('\n  Suggestion: $suggestion');
    return buffer.toString();
  }
}
