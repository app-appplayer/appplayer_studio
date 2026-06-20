import 'dart:io';

/// Lightweight logger for the makemind Ops app.
///
/// Writes structured records to both stderr (for the running console) and
/// `~/.makemind-ops/boot.log` (for post-mortem inspection). Replaces the
/// scattered `stderr.writeln` + `File.writeAsStringSync` calls that were
/// previously duplicated across boot paths.
///
/// Levels are intentionally minimal — boot/info/warn/error — and the API is
/// synchronous so call sites can keep their existing trace-style usage.
class OpsLog {
  OpsLog._();

  static File? _file;

  static File _logFile() {
    final cached = _file;
    if (cached != null) return cached;
    final home = Platform.environment['HOME'] ?? '.';
    final f = File('$home/.makemind-ops/boot.log');
    f.parent.createSync(recursive: true);
    _file = f;
    return f;
  }

  static void boot(String tag, String message) => _emit('boot', tag, message);

  static void info(String tag, String message) => _emit('info', tag, message);

  static void warn(String tag, String message) => _emit('warn', tag, message);

  static void error(
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final detail = StringBuffer(message);
    if (error != null) detail.write(' :: $error');
    _emit('error', tag, detail.toString());
    if (stackTrace != null) _emit('error', tag, stackTrace.toString());
  }

  static void _emit(String level, String tag, String message) {
    final line = '[$level][$tag] $message';
    stderr.writeln(line);
    try {
      _logFile().writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // Logging must never break the caller — silently drop the file write
      // when the home directory is read-only (CI sandboxes).
    }
  }
}
