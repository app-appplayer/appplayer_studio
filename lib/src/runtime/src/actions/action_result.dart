/// Result of an action execution
///
/// Supports the unified result envelope pattern from the design spec:
/// Success: `{success: true, data: ..., timestamp: ...}`
/// Error: `{success: false, error: {code: ..., message: ..., details: ...}, timestamp: ...}`
class ActionResult {
  /// Error code of an action that ran out of its `timeout` (§4.16).
  static const String timeoutCode = 'TIMEOUT';

  /// Error code of an action ended by `cancel` or page removal (§4.15).
  static const String cancelledCode = 'CANCELLED';

  final bool success;
  final String? error;
  final String? errorCode;
  final Map<String, dynamic>? errorDetails;
  final dynamic data;
  final DateTime timestamp;

  ActionResult._({
    required this.success,
    this.error,
    this.errorCode,
    this.errorDetails,
    this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create a successful result
  factory ActionResult.success({dynamic data}) {
    return ActionResult._(
      success: true,
      data: data,
    );
  }

  /// Create an error result
  factory ActionResult.error(String message,
      {String? errorCode, Map<String, dynamic>? errorDetails}) {
    return ActionResult._(
      success: false,
      error: message,
      errorCode: errorCode,
      errorDetails: errorDetails,
    );
  }

  /// Convert to the unified result envelope JSON
  Map<String, dynamic> toEnvelope() {
    if (success) {
      return {
        'success': true,
        'data': data,
        'timestamp': timestamp.toIso8601String(),
      };
    } else {
      return {
        'success': false,
        'error': {
          if (errorCode != null) 'code': errorCode,
          'message': error ?? 'Unknown error',
          if (errorDetails != null) 'details': errorDetails,
        },
        'timestamp': timestamp.toIso8601String(),
      };
    }
  }

  @override
  String toString() {
    if (success) {
      return 'ActionResult.success(data: $data)';
    } else {
      return 'ActionResult.error($error)';
    }
  }
}
