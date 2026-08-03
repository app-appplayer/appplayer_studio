import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// One line of runtime diagnostics.
class MCPLogRecord {
  const MCPLogRecord({
    required this.level,
    required this.logger,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// `DEBUG` · `INFO` · `WARN` · `ERROR`.
  final String level;

  /// Which subsystem spoke.
  final String logger;

  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  @override
  String toString() => '[$level] [$logger] $message';
}

/// Logger for MCP UI Runtime that outputs debug messages.
///
/// In debug mode, uses dart:developer log for output. In release mode,
/// logging is disabled by default to avoid performance impact.
///
/// **A host that wants these must install [onRecord].** Everything else the
/// runtime says goes to `dart:developer`, which reaches whoever has DevTools
/// open and nobody else — and some of what it says is meant for the person
/// writing the document, not for whoever is debugging the app. A warning that
/// a theme role was declared and dropped is useless in a channel the author
/// never looks at. `stdout` is not an option: on a stdio MCP connection it is
/// the protocol.
class MCPLogger {
  final String name;
  final bool enableLogging;

  MCPLogger(this.name, {bool? enableLogging})
      : enableLogging = enableLogging ?? kDebugMode;

  /// Receives every record, in every build mode.
  ///
  /// Deliberately independent of [enableLogging]: that flag decides whether
  /// the runtime talks to `dart:developer`, and defaults to debug-only so a
  /// release build pays nothing. A host that installed a sink has asked for
  /// the records, and dropping them in release would silence exactly the
  /// diagnostics a released app needs to surface.
  static void Function(MCPLogRecord record)? onRecord;

  static void _emit(MCPLogRecord record) {
    final sink = onRecord;
    if (sink == null) return;
    try {
      sink(record);
    } catch (_) {
      // A host whose sink throws must not take the runtime down with it.
    }
  }

  /// Log a debug message
  void debug(String message) {
    _emit(MCPLogRecord(level: 'DEBUG', logger: name, message: message));
    if (!enableLogging) return;
    _log('DEBUG', message);
  }

  /// Log an info message
  void info(String message) {
    _emit(MCPLogRecord(level: 'INFO', logger: name, message: message));
    if (!enableLogging) return;
    _log('INFO', message);
  }

  /// Log a warning message
  void warning(String message) {
    _emit(MCPLogRecord(level: 'WARN', logger: name, message: message));
    if (!enableLogging) return;
    _log('WARN', message);
  }

  /// Log an error message
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    _emit(MCPLogRecord(
      level: 'ERROR',
      logger: name,
      message: message,
      error: error,
      stackTrace: stackTrace,
    ));
    if (!enableLogging) return;
    _log('ERROR', message);
    if (error != null) {
      _log('ERROR', '  Error: $error');
    }
    if (stackTrace != null) {
      _log('ERROR', '  Stack trace:\n$stackTrace');
    }
  }

  void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    // Use dart:developer log instead of debugPrint to avoid throttling
    developer.log(
      '[$timestamp] [$level] [$name] $message',
      name: name,
      level: level == 'ERROR' ? 1000 : 0,
    );
  }

  /// Factory constructor for creating a logger with a specific name
  factory MCPLogger.forClass(Type type, {bool? enableLogging}) {
    return MCPLogger(type.toString(), enableLogging: enableLogging);
  }
}
