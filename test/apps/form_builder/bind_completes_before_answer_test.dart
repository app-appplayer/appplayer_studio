/// A Form Builder bind completes only once `form.*` persists to the bound
/// project: every caller of `ensureBoot` for the same root — the chrome
/// open/new slots included — waits for the capability rebind, so a template
/// saved right after an open is kept instead of landing in the unbound
/// in-memory port.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/apps/form_builder/form_builder_builtin.dart';
import 'package:appplayer_studio/src/apps/form_builder/infra/project_seed.dart';
import 'package:appplayer_studio/src/base/install/capability_tools.dart'
    show registerFormCapability;
import 'package:appplayer_studio/src/base/install/form_capability_store.dart'
    show FormCapabilityBinding;
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _template(String version) => <String, dynamic>{
  'templateId': 'kept',
  'version': version,
  'name': 'Kept',
  'schema': <String, dynamic>{
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{'name': 'title', 'type': 'string'},
    ],
  },
  'defaultSections': <Map<String, dynamic>>[
    <String, dynamic>{
      'sectionId': 'main',
      'index': 0,
      'title': 'Kept',
      'blocks': <Map<String, dynamic>>[
        <String, dynamic>{
          'blockId': 'b-title',
          'type': 'formField',
          'index': 0,
          'fieldName': 'title',
          'fieldType': 'text',
        },
      ],
    },
  ],
  'layoutPolicy': <String, dynamic>{
    'pageSize': <String, dynamic>{'size': 'A4', 'width': 210, 'height': 297},
    'margins': <String, dynamic>{
      'top': 20,
      'right': 20,
      'bottom': 20,
      'left': 20,
    },
    'fontPolicy': <String, dynamic>{
      'defaultFont': 'sans-serif',
      'defaultSize': 12,
      'headingSize': 18,
      'bodySize': 12,
      'minSize': 8,
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late mk.InProcessKernelServerHost host;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('form_bind_');
    await applyFormProjectSeed(tmp.path, 'bind');
    host = mk.InProcessKernelServerHost(name: 'studio', version: '0');
    final registry = mk.HostToolRegistry(
      endpoint: host,
      attachToDispatcher: (_, _) {},
      detachFromDispatcher: (_) {},
    );
    registerFormCapability(registry);
    FormCapabilityBinding.install(registry);
  });

  tearDown(() async {
    await FormBuilderBuiltInApp.closeProject();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> a) async {
    final r = await host.callTool(name, a);
    return jsonDecode((r.content.first as mk.KernelTextContent).text)
        as Map<String, dynamic>;
  }

  test(
    'a save right after a second ensureBoot persists to the project',
    () async {
      // The first caller starts the boot; the second (an open slot) awaits the
      // same root.
      final first = FormBuilderBuiltInApp.ensureBoot(tmp.path);
      await FormBuilderBuiltInApp.ensureBoot(tmp.path);
      final saved = await call('form.save_template', {
        'template': _template('1.0.0'),
      });
      expect(saved['version'], '1.0.0');
      await first;

      // Re-hydrate from the project's facts: the template must be there.
      await FormBuilderBuiltInApp.closeProject();
      await FormBuilderBuiltInApp.ensureBoot(tmp.path);
      final versions = await call('form.get_template_versions', {
        'templateId': 'kept',
      });
      expect(
        (versions['versions'] as List).map((v) => (v as Map)['version']),
        contains('1.0.0'),
      );
    },
  );
}
