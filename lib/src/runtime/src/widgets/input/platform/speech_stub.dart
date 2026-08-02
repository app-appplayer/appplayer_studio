/// Whether speech capture is available without host help.
bool get speechSupported => false;

/// A live capture session.
abstract class SpeechSession {
  void stop();
}

/// Starts capture. Never called when [speechSupported] is false.
SpeechSession? startSpeech({
  required String? language,
  required bool continuous,
  required bool interimResults,
  required void Function(String text, bool isFinal) onResult,
  required void Function(String message) onError,
  required void Function() onEnd,
}) =>
    null;
