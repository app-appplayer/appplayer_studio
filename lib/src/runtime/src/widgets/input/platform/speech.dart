/// Platform-split speech recognition (spec §2.6.29).
///
/// The web exposes SpeechRecognition directly, so that branch works with no
/// dependency. Native platforms need a plugin, which would land on every host
/// embedding this runtime — so the native branch declares itself unsupported
/// and the widget reports through `onError` rather than rendering a control
/// that does nothing.
library speech;

export 'speech_stub.dart' if (dart.library.js_interop) 'speech_web.dart';
