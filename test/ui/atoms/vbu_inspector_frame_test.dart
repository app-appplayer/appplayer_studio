/// `inspectorFrameFor` (inspector_render.dart) — pure function returning
/// a `DeviceFrame` for the chosen size/orientation pair. No live I/O needed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  test('mobile portrait returns phone-portrait frame', () {
    final frame = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.portrait,
    );
    expect(frame.logicalSize.width, lessThan(frame.logicalSize.height));
  });

  test('mobile landscape swaps width and height', () {
    final portrait = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.portrait,
    );
    final landscape = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.landscape,
    );
    expect(landscape.logicalSize.width, portrait.logicalSize.height);
    expect(landscape.logicalSize.height, portrait.logicalSize.width);
  });

  test('tablet portrait returns larger than mobile portrait', () {
    final mobile = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.portrait,
    );
    final tablet = inspectorFrameFor(
      InspectorSize.tablet,
      InspectorOrient.portrait,
    );
    expect(tablet.logicalSize.width, greaterThan(mobile.logicalSize.width));
  });

  test('desktop portrait is wider than tablet portrait', () {
    final tablet = inspectorFrameFor(
      InspectorSize.tablet,
      InspectorOrient.portrait,
    );
    final desktop = inspectorFrameFor(
      InspectorSize.desktop,
      InspectorOrient.portrait,
    );
    expect(
      desktop.logicalSize.width,
      greaterThanOrEqualTo(tablet.logicalSize.width),
    );
  });

  test('custom size uses supplied dimensions', () {
    final frame = inspectorFrameFor(
      InspectorSize.custom,
      InspectorOrient.portrait,
      customW: 480,
      customH: 960,
    );
    expect(frame.logicalSize.width, 480);
    expect(frame.logicalSize.height, 960);
  });

  test('custom landscape swaps supplied dimensions', () {
    final frame = inspectorFrameFor(
      InspectorSize.custom,
      InspectorOrient.landscape,
      customW: 480,
      customH: 960,
    );
    expect(frame.logicalSize.width, 960);
    expect(frame.logicalSize.height, 480);
  });

  test('frame id includes orientation name', () {
    final portrait = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.portrait,
    );
    final landscape = inspectorFrameFor(
      InspectorSize.mobile,
      InspectorOrient.landscape,
    );
    expect(portrait.id, contains('portrait'));
    expect(landscape.id, contains('landscape'));
  });
}
