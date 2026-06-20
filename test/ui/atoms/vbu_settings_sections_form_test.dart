/// `VbuSettingsSectionsForm` — schema-driven settings form rendering
/// `VbuSettingsSection` list with per-field control dispatch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_studio/base.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child));

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('renders section label uppercased', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuSettingsSectionsForm(
          sections: <VbuSettingsSection>[
            VbuSettingsSection(
              key: 's1',
              label: 'General',
              fields: <VbuSettingsField>[],
            ),
          ],
        ),
      ),
    );
    expect(find.text('GENERAL'), findsOneWidget);
  });

  testWidgets('renders no-sections placeholder', (tester) async {
    await tester.pumpWidget(
      _wrap(const VbuSettingsSectionsForm(sections: <VbuSettingsSection>[])),
    );
    expect(find.textContaining('no sections'), findsOneWidget);
  });

  testWidgets('renders multiple section labels', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const VbuSettingsSectionsForm(
          sections: <VbuSettingsSection>[
            VbuSettingsSection(
              key: 's1',
              label: 'Network',
              fields: <VbuSettingsField>[],
            ),
            VbuSettingsSection(
              key: 's2',
              label: 'Security',
              fields: <VbuSettingsField>[],
            ),
          ],
        ),
      ),
    );
    expect(find.text('NETWORK'), findsOneWidget);
    expect(find.text('SECURITY'), findsOneWidget);
  });

  testWidgets('renders text field row', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuSettingsSectionsForm(
          sections: <VbuSettingsSection>[
            VbuSettingsSection(
              key: 's1',
              label: 'Endpoint',
              fields: <VbuSettingsField>[
                VbuSettingsField(
                  key: 'url',
                  label: 'URL',
                  type: 'text',
                  value: 'http://localhost',
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.text('URL'), findsOneWidget);
  });

  testWidgets('renders toggle field row with checkbox icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        VbuSettingsSectionsForm(
          sections: <VbuSettingsSection>[
            VbuSettingsSection(
              key: 's1',
              label: 'Options',
              fields: <VbuSettingsField>[
                VbuSettingsField(
                  key: 'enabled',
                  label: 'Enabled',
                  type: 'toggle',
                  value: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.text('Enabled'), findsOneWidget);
    // VbuLabelledToggle renders a check_box icon, not a Switch widget.
    expect(find.byIcon(Icons.check_box), findsOneWidget);
  });

  testWidgets('toggle callback fires when label row is tapped', (tester) async {
    Object? changed;
    await tester.pumpWidget(
      _wrap(
        VbuSettingsSectionsForm(
          sections: <VbuSettingsSection>[
            VbuSettingsSection(
              key: 's1',
              label: 'Options',
              fields: <VbuSettingsField>[
                VbuSettingsField(
                  key: 'flag',
                  label: 'FlagToggle',
                  type: 'toggle',
                  value: false,
                  onChanged: (v) => changed = v,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('FlagToggle'));
    await tester.pumpAndSettle();
    expect(changed, isNotNull);
  });
}
