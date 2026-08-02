import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// The browser exposes recognition natively on all current engines that
/// implement it; where it does not, [startSpeech] returns null and the widget
/// reports rather than pretending to listen.
bool get speechSupported => _recognitionConstructor != null;

@JS('window')
external JSObject get _window;

JSFunction? get _recognitionConstructor {
  // `isA<JSFunction>` would be cleaner but needs Dart 3.4; this package still
  // supports 3.0 consumers, and a null check is enough here — the property is
  // either the constructor or absent.
  final direct = _window.getProperty<JSAny?>('SpeechRecognition'.toJS);
  if (direct != null) return direct as JSFunction;
  final prefixed = _window.getProperty<JSAny?>('webkitSpeechRecognition'.toJS);
  if (prefixed != null) return prefixed as JSFunction;
  return null;
}

abstract class SpeechSession {
  void stop();
}

class _WebSession implements SpeechSession {
  _WebSession(this._recognition);
  final JSObject _recognition;

  @override
  void stop() {
    _recognition.getProperty<JSFunction>('stop'.toJS).callAsFunction(_recognition);
  }
}

SpeechSession? startSpeech({
  required String? language,
  required bool continuous,
  required bool interimResults,
  required void Function(String text, bool isFinal) onResult,
  required void Function(String message) onError,
  required void Function() onEnd,
}) {
  final ctor = _recognitionConstructor;
  if (ctor == null) return null;

  final recognition = ctor.callAsConstructor<JSObject>();
  if (language != null) {
    recognition.setProperty('lang'.toJS, language.toJS);
  }
  recognition.setProperty('continuous'.toJS, continuous.toJS);
  recognition.setProperty('interimResults'.toJS, interimResults.toJS);

  recognition.setProperty(
    'onresult'.toJS,
    ((JSObject event) {
      final results = event.getProperty<JSObject>('results'.toJS);
      final length = results.getProperty<JSNumber>('length'.toJS).toDartInt;
      for (var i = 0; i < length; i++) {
        final result = results.getProperty<JSObject>(i.toString().toJS);
        final isFinal =
            result.getProperty<JSBoolean?>('isFinal'.toJS)?.toDart ?? false;
        final alternative = result.getProperty<JSObject?>('0'.toJS);
        final transcript =
            alternative?.getProperty<JSString?>('transcript'.toJS)?.toDart;
        if (transcript != null) onResult(transcript, isFinal);
      }
    }).toJS,
  );

  recognition.setProperty(
    'onerror'.toJS,
    ((JSObject event) {
      final code = event.getProperty<JSString?>('error'.toJS)?.toDart;
      // A denied microphone arrives here, which is what keeps a refusal from
      // looking like silence.
      onError(code ?? 'speech recognition failed');
    }).toJS,
  );

  recognition.setProperty('onend'.toJS, (() => onEnd()).toJS);

  recognition.getProperty<JSFunction>('start'.toJS).callAsFunction(recognition);
  return _WebSession(recognition);
}
