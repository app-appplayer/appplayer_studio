import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import 'platform/speech.dart';

/// Factory for `voiceInput` (spec §2.6.29, Client Profile).
///
/// Client Profile rather than Core, and the line is worth restating: picking a
/// file is one act of choosing and the choosing is the consent, while a
/// microphone is a continuous capture of the room including whoever else is in
/// it. There is no composition that reaches it — microphone access is a host
/// capability — which is why the widget exists at all.
class VoiceInputFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final binding = properties['binding'] as String?;
    final language = context.resolve<String?>(properties['language']);
    final continuous = context.resolve<bool?>(properties['continuous']) ?? false;
    final interim = context.resolve<bool?>(properties['interimResults']) ?? false;
    final maxDuration = context.resolve<num?>(properties['maxDuration'])?.toInt();
    final showWaveform =
        context.resolve<bool?>(properties['showWaveform']) ?? true;
    final enabled = context.resolve<bool?>(properties['enabled']) ?? true;

    void emit(String name, Map<String, dynamic> event) {
      final action = properties[name] as Map<String, dynamic>?;
      if (action == null) return;
      context.actionHandler.execute(
        action,
        context.createChildContext(variables: {'event': event}),
      );
    }

    return _VoiceInput(
      enabled: enabled,
      language: language,
      continuous: continuous,
      interimResults: interim,
      maxDuration: maxDuration,
      showWaveform: showWaveform,
      onTranscript: (text, isFinal) {
        if (binding != null) context.setValue(binding, text);
        emit('onResult', {'value': text, 'isFinal': isFinal, 'type': 'result'});
      },
      onStart: () => emit('onStart', {'type': 'start'}),
      onEnd: () => emit('onEnd', {'type': 'end'}),
      onError: (message) =>
          emit('onError', {'type': 'error', 'message': message}),
    );
  }
}

class _VoiceInput extends StatefulWidget {
  const _VoiceInput({
    required this.enabled,
    required this.continuous,
    required this.interimResults,
    required this.showWaveform,
    required this.onTranscript,
    required this.onStart,
    required this.onEnd,
    required this.onError,
    this.language,
    this.maxDuration,
  });

  final bool enabled;
  final bool continuous;
  final bool interimResults;
  final bool showWaveform;
  final String? language;
  final int? maxDuration;
  final void Function(String text, bool isFinal) onTranscript;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final void Function(String) onError;

  @override
  State<_VoiceInput> createState() => _VoiceInputState();
}

class _VoiceInputState extends State<_VoiceInput> {
  SpeechSession? _session;
  bool _listening = false;

  @override
  void dispose() {
    _session?.stop();
    super.dispose();
  }

  void _start() {
    if (!speechSupported) {
      // Declared, not silent: a control that renders and does nothing is worse
      // than one that says it cannot run.
      widget.onError('Speech capture is not available on this platform');
      return;
    }
    final session = startSpeech(
      language: widget.language,
      continuous: widget.continuous,
      interimResults: widget.interimResults,
      onResult: widget.onTranscript,
      onError: (message) {
        setState(() => _listening = false);
        widget.onError(message);
      },
      onEnd: () {
        setState(() => _listening = false);
        widget.onEnd();
      },
    );
    if (session == null) {
      widget.onError('Speech capture could not start');
      return;
    }
    setState(() {
      _session = session;
      _listening = true;
    });
    // Fired after the grant, not before.
    widget.onStart();

    if (widget.maxDuration != null) {
      // A microphone with no ceiling is a microphone left on.
      Future.delayed(Duration(seconds: widget.maxDuration!), () {
        if (mounted && _listening) _stop();
      });
    }
  }

  void _stop() {
    _session?.stop();
    setState(() {
      _session = null;
      _listening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(_listening ? Icons.stop : Icons.mic),
          color: _listening ? scheme.error : null,
          tooltip: _listening ? 'Stop' : 'Start voice input',
          onPressed: widget.enabled ? (_listening ? _stop : _start) : null,
        ),
        // The user's continuous evidence that capture is running; kept even
        // when the waveform is off, because silence about a live microphone is
        // the wrong default.
        if (_listening)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showWaveform)
                SizedBox(
                  width: 48,
                  height: 16,
                  child: LinearProgressIndicator(color: scheme.error),
                ),
              const SizedBox(width: 6),
              Text('Listening', style: TextStyle(color: scheme.error)),
            ],
          ),
      ],
    );
  }
}
