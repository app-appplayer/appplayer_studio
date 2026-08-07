/// The studio declares the platform powers it actually wired (UI DSL §6.13).
///
/// With nothing wired the engine reports every media capability absent and
/// `mediaPlayer` / `lottieAnimation` / `map` draw NOTHING — §6.13.1 forbids a
/// stand-in, so the widget an author just placed simply vanishes from the
/// preview. That is the state this replaced, and it came back silently: no
/// error, no log, just empty space.
///
/// The set must also not over-claim. `declared` is derived from which ports are
/// non-null, so a build that drops a plugin reports the truth and the affected
/// document gets `onError` instead of a dead frame.
@TestOn('vm')
library;

import 'package:appplayer_studio/runtime.dart' show RuntimeCapability;
import 'package:appplayer_studio/src/base/media/studio_media_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the media capabilities the preview needs are declared', () {
    final caps = studioRuntimeCapabilities();

    // Each of these is a widget that renders nothing without its port.
    expect(caps.declared, contains(RuntimeCapability.audio),
        reason: 'mediaPlayer(audio) draws nothing');
    expect(caps.declared, contains(RuntimeCapability.video),
        reason: 'mediaPlayer(video) draws nothing');
    expect(caps.declared, contains(RuntimeCapability.lottie),
        reason: 'lottieAnimation draws nothing');
    expect(caps.declared, contains(RuntimeCapability.sound),
        reason: 'sound.play does nothing');
  });

  test('video is declared only because the port really decodes it', () {
    // The flag is separate from `media` for embedded hosts that are audio-only.
    // Claiming it falsely moves the failure from an up-front report to a play
    // -time error, which is the thing §6.13 exists to prevent.
    final caps = studioRuntimeCapabilities();
    expect(caps.media, isNotNull);
    expect(caps.mediaSupportsVideo, isTrue);
  });

  test('the set is built once', () {
    // The ports hold decoder/plugin handles; a fresh set per render would leave
    // the previous one's players open and unreferenced.
    expect(identical(studioRuntimeCapabilities(), studioRuntimeCapabilities()),
        isTrue);
  });
}
