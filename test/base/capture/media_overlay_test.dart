/// Unit tests for the media overlay surface added for video-lecture
/// production: file-or-asset image resolution (`imageFromProps`),
/// entrance motion (`applyMotion`), and the full-frame presentation
/// `SlideOverlay`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/base/capture/overlay/painters/media.dart';

void main() {
  group('imageFromProps — source resolution', () {
    test('path wins → Image.file', () {
      final w = imageFromProps(
        <String, dynamic>{'path': '/tmp/slide-1.png', 'asset': 'a.png'},
        width: 100,
        height: 80,
      );
      expect(w, isA<Image>());
      // Image.file builds a FileImage provider.
      expect((w! as Image).image, isA<FileImage>());
    });

    test('asset only → Image.asset', () {
      final w = imageFromProps(
        <String, dynamic>{'asset': 'assets/logo.png'},
        width: null,
        height: null,
      );
      expect(w, isA<Image>());
      expect((w! as Image).image, isA<AssetImage>());
    });

    test('neither path nor asset → null', () {
      final w = imageFromProps(
        const <String, dynamic>{'text': 'no image'},
        width: 10,
        height: 10,
      );
      expect(w, isNull);
    });
  });

  group('applyMotion — entrance transform', () {
    const child = SizedBox(width: 1, height: 1);

    test('none / empty returns the child unchanged', () {
      expect(applyMotion(child, 'none', 0.5), same(child));
      expect(applyMotion(child, '', 0.5), same(child));
    });

    test('scale wraps in a Transform', () {
      expect(applyMotion(child, 'scale', 0.5), isA<Transform>());
    });

    test('rise / slideLeft wrap in a Transform', () {
      expect(applyMotion(child, 'rise', 0.5), isA<Transform>());
      expect(applyMotion(child, 'slideLeft', 0.5), isA<Transform>());
    });

    test('unknown motion falls through to the child', () {
      expect(applyMotion(child, 'wobble', 0.5), same(child));
    });
  });

  group('SlideOverlay — presentation insertion', () {
    testWidgets('renders a caption strip over the backdrop', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[
              SlideOverlay(
                props: <String, dynamic>{
                  'caption': 'Step 1 — open App Builder',
                  'background': '#101418',
                },
              ),
            ],
          ),
        ),
      );
      expect(find.text('Step 1 — open App Builder'), findsOneWidget);
    });

    testWidgets('no caption → no text, still fills the frame', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[SlideOverlay(props: <String, dynamic>{})],
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
      expect(find.byType(SlideOverlay), findsOneWidget);
    });
  });
}
