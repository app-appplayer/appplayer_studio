/// Studio viewer kit — [VbuDocumentViewer] renders by file kind and the
/// view/edit/save chrome behaves (Studio viewer kit L0).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/ui/atoms/vbu_document_viewer.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 600, height: 400, child: child)),
    );

void main() {
  test('kind detection by extension', () {
    expect(vbuDocKindForPath('a/b/readme.md'), VbuDocKind.markdown);
    expect(vbuDocKindForPath('main.dart'), VbuDocKind.code);
    expect(vbuDocKindForPath('data.csv'), VbuDocKind.code);
    expect(vbuDocKindForPath('logo.png'), VbuDocKind.image);
    expect(vbuDocKindForPath('report.pdf'), VbuDocKind.pdf);
    expect(vbuDocKindForPath('archive.zip'), VbuDocKind.binary);
    expect(vbuDocKindForPath('LICENSE'), VbuDocKind.code); // extensionless
  });

  testWidgets('markdown renders its heading text', (tester) async {
    await tester.pumpWidget(_wrap(const VbuDocumentViewer(
      path: 'doc.md',
      text: '# Hello Title\n\nbody',
    )));
    await tester.pumpAndSettle();
    expect(find.text('doc.md'), findsOneWidget); // toolbar filename
    expect(find.textContaining('Hello Title'), findsWidgets);
  });

  testWidgets('code shows the text and no edit chrome when not editable',
      (tester) async {
    await tester.pumpWidget(_wrap(const VbuDocumentViewer(
      path: 'main.dart',
      text: 'void main() {}',
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('void main()'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('pdf shows the pending placeholder', (tester) async {
    await tester.pumpWidget(_wrap(const VbuDocumentViewer(path: 'a.pdf')));
    await tester.pumpAndSettle();
    expect(find.textContaining('PDF preview pending'), findsOneWidget);
  });

  testWidgets('image renders from bytes', (tester) async {
    // 1x1 transparent PNG.
    final png = Uint8List.fromList(<int>[
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
      0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, //
      13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
    ]);
    await tester.pumpWidget(_wrap(VbuDocumentViewer(path: 'x.png', bytes: png)));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('editable text → edit, change, Save fires onSave', (tester) async {
    String? saved;
    await tester.pumpWidget(_wrap(VbuDocumentViewer(
      path: 'note.txt',
      text: 'original',
      editable: true,
      onSave: (t) => saved = t,
    )));
    await tester.pumpAndSettle();

    // Enter edit mode.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Change text → Save appears (dirty).
    await tester.enterText(find.byType(TextField), 'edited content');
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, 'edited content');
  });
}
