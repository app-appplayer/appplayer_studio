import 'dart:convert' show base64Decode, utf8;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_form/mcp_form.dart'
    show TrueTypeFont, standardRendererRegistry;
import 'package:mcp_knowledge/mcp_knowledge.dart' show KnowledgeSystem;

import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show CapabilityTool, FactBackedFormTemplatePort, formCapabilityTools;
import 'package:appplayer_studio/src/base/install/form_capability_store.dart';
import 'package:appplayer_studio/src/base/install/knowledge_persistence/knowledge_persistence.dart'
    show assemblePersistentKnowledgeSystem;

// End-to-end over the exact assembly Studio registers as `form.*`:
// the vendored recipe surface + the fact-backed template port over the
// kernel store. Covers the render path (dead until the engine's
// `standardRendererRegistry` fix) and the C1/C2 verbs the LLM fill flow
// depends on.
void main() {
  late Directory projectRoot;
  late KnowledgeSystem system;
  late Map<String, CapabilityTool> tools;

  Future<Object?> call(String verb, Map<String, dynamic> args) {
    final tool = tools[verb];
    expect(tool, isNotNull, reason: 'form.$verb must be on the surface');
    return tool!.invoke(args);
  }

  setUp(() async {
    projectRoot = await Directory.systemTemp.createTemp('form_e2e');
    system = await assemblePersistentKnowledgeSystem(
      projectRoot: projectRoot.path,
      projectId: 'proj-e2e',
    );
    final port = await FactBackedFormTemplatePort.hydrate(
      KernelFormTemplateFactStore(facts: system.facts, workspaceId: 'proj-e2e'),
    );
    tools = <String, CapabilityTool>{
      for (final t in formCapabilityTools(templatePort: port)) t.verb: t,
    };
  });

  tearDown(() async {
    if (await projectRoot.exists()) {
      await projectRoot.delete(recursive: true);
    }
  });

  Map<String, dynamic> template() => <String, dynamic>{
    'templateId': 'quote',
    'version': '1.0.0',
    'name': 'Quotation',
    'schema': <String, dynamic>{
      'fields': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'title', 'type': 'string'},
        <String, dynamic>{'name': 'total', 'type': 'string'},
      ],
    },
    // Renderable content comes from sections/blocks — a schema alone renders
    // an empty body (DocumentFactory falls back to one empty 'main' section).
    'defaultSections': <Map<String, dynamic>>[
      <String, dynamic>{
        'sectionId': 'main',
        'index': 0,
        'title': 'Quotation',
        'blocks': <Map<String, dynamic>>[
          <String, dynamic>{
            'blockId': 'b-title',
            'type': 'formField',
            'index': 0,
            'fieldName': 'title',
            'fieldType': 'text',
          },
          <String, dynamic>{
            'blockId': 'b-total',
            'type': 'formField',
            'index': 1,
            'fieldName': 'total',
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

  test('surface carries 14 verbs incl. get_document', () {
    expect(
      tools.keys,
      containsAll(<String>[
        'list_templates',
        'save_template',
        'get_template',
        'delete_template',
        'get_template_versions',
        'create_document',
        'patch',
        'validate',
        'render',
        'export',
        'get_status',
        'get_document',
        'template_schema',
        'capacity',
      ]),
    );
  });

  test('save → create → render html produces real bytes (fact-backed port)',
      () async {
    await call('save_template', {'template': template()});

    final created = (await call('create_document', {
      'templateId': 'quote',
      'data': <String, dynamic>{'title': 'Q-1', 'total': 'USD 100'},
    }))! as Map<String, dynamic>;
    final documentId = created['documentId'] as String;

    final rendered = (await call('render', {
      'documentId': documentId,
      'format': 'html',
    }))! as Map<String, dynamic>;
    final html = utf8.decode(base64Decode(rendered['data'] as String));
    expect(html, contains('Q-1'));
  });

  test('template_schema (C1) constrains the fill to schema fields', () async {
    await call('save_template', {'template': template()});
    final out = (await call('template_schema', {
      'templateId': 'quote',
    }))! as Map<String, dynamic>;
    final schema = (out['schema'] ?? out) as Map;
    expect('$schema', contains('title'));
    expect('$schema', contains('total'));
  });

  test('capacity (C2) answers with a capacities report', () async {
    await call('save_template', {'template': template()});
    final out = (await call('capacity', {'templateId': 'quote'}))!
        as Map<String, dynamic>;
    // Shape smoke — per-field numbers need fixed-box constraints, which this
    // minimal template doesn't declare; the verb itself must answer.
    expect(out['templateId'], 'quote');
    expect(out.containsKey('capacities'), isTrue);
  });

  test('get_document returns the typed document WITH patches applied',
      () async {
    final tpl = template();
    ((tpl['defaultSections'] as List).first['blocks'] as List).add({
      'blockId': 'items',
      'type': 'table',
      'index': 2,
      'columns': [
        {'id': 'name', 'title': 'item', 'type': 'string'},
      ],
      'rows': [
        {
          'cells': {'name': 'template-example'},
        },
      ],
    });
    await call('save_template', {'template': tpl});
    final created = (await call('create_document', {
      'templateId': 'quote',
      'data': {'title': 'Q-2', 'total': 'USD 1'},
    }))! as Map<String, dynamic>;
    final documentId = created['documentId'] as String;
    await call('patch', {
      'documentId': documentId,
      'patches': [
        {
          'op': 'replace',
          'path': '/sections/0/blocks/2/rows',
          'value': [
            {
              'cells': {'name': 'patched-row'},
            },
          ],
        },
      ],
    });
    final out = (await call('get_document', {'documentId': documentId}))!
        as Map<String, dynamic>;
    final doc = (out['document'] as Map).cast<String, dynamic>();
    expect(doc['documentId'], documentId);
    final blocks =
        ((doc['sections'] as List).first as Map)['blocks'] as List;
    final items =
        blocks.cast<Map>().firstWhere((b) => b['blockId'] == 'items');
    expect(
      ((items['rows'] as List).first as Map)['cells']?['name'],
      'patched-row',
      reason: 'the snapshot must carry patch results, not template rows',
    );
  });

  test('placement style renders as an absolute overlay in HTML', () async {
    // Engine placement is image-block scoped (the seal/stamp case) — text
    // blocks stay in flow (in-app FormView places any block; fidelity note).
    final tpl = template();
    ((tpl['defaultSections'] as List).first['blocks'] as List).add({
      'blockId': 'seal',
      'type': 'image',
      'index': 2,
      'src': 'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
          'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      'maxWidth': 80,
      'style': {
        'placement': {'anchor': 'bottom-left', 'x': 20, 'y': 20},
      },
    });
    await call('save_template', {'template': tpl});
    final created = (await call('create_document', {
      'templateId': 'quote',
      'data': {'title': 'Q-3', 'total': 'USD 2'},
    }))! as Map<String, dynamic>;
    final rendered = (await call('render', {
      'documentId': created['documentId'],
      'format': 'html',
    }))! as Map<String, dynamic>;
    final html = utf8.decode(base64Decode(rendered['data'] as String));
    expect(
      html,
      contains('position: absolute; bottom: 20.0mm; left: 20.0mm;'),
      reason: 'placement must leave the flow and pin to the page corner',
    );
    expect(
      html,
      contains('min-height:'),
      reason: 'short documents must keep a full page box so bottom anchors '
          'mean the PAPER bottom, not "right below the last line"',
    );
  });

  test('placement on a TEXT block leaves the flow too (PDF and HTML)',
      () async {
    final tpl = template();
    ((tpl['defaultSections'] as List).first['blocks'] as List).add({
      'blockId': 'company',
      'type': 'text',
      'index': 2,
      'content': 'PLACED-COMPANY',
      'style': {
        'placement': {'anchor': 'bottom-center', 'x': 0, 'y': 12},
      },
    });
    await call('save_template', {'template': tpl});
    final created = (await call('create_document', {
      'templateId': 'quote',
      'data': {'title': 'Q-4', 'total': 'USD 3'},
    }))! as Map<String, dynamic>;
    final html = utf8.decode(base64Decode(
      ((await call('render', {
        'documentId': created['documentId'],
        'format': 'html',
      }))! as Map<String, dynamic>)['data'] as String,
    ));
    expect(html, contains('PLACED-COMPANY'));
    expect(
      RegExp('position: absolute[^>]*translateX').hasMatch(html) ||
          html.contains('position: absolute; bottom: 12.0mm;'),
      isTrue,
      reason: 'a placed text block must render as an absolute overlay',
    );
    final pdfOut = (await call('render', {
      'documentId': created['documentId'],
      'format': 'pdf',
    }))! as Map<String, dynamic>;
    expect(pdfOut['pageCount'], 1);
  });

  test('image format renders real PNG pixels (pure-Dart renderer)', () async {
    await call('save_template', {'template': template()});
    final created = (await call('create_document', {
      'templateId': 'quote',
      'data': {'title': 'Card', 'total': 'USD 4'},
    }))! as Map<String, dynamic>;
    final rendered = (await call('render', {
      'documentId': created['documentId'],
      'format': 'image',
    }))! as Map<String, dynamic>;
    final bytes = base64Decode(rendered['data'] as String);
    expect(bytes.length, greaterThan(8));
    expect(
      bytes.sublist(0, 8),
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: 'format:image must produce a real PNG',
    );
  });

  test(
      'PDF embeds the injected CJK font (Hangul survives instead of "?")',
      () async {
    // The exact seam the host wires: standardRendererRegistry(embeddedFont:).
    final fontFile = File(
      '/System/Library/Fonts/Supplemental/AppleGothic.ttf',
    );
    if (!fontFile.existsSync()) {
      markTestSkipped('no system CJK font on this machine');
      return;
    }
    final gothic = TrueTypeFont.parse(fontFile.readAsBytesSync());
    final port = await FactBackedFormTemplatePort.hydrate(
      KernelFormTemplateFactStore(facts: system.facts, workspaceId: 'p-cjk'),
    );
    final cjkTools = <String, CapabilityTool>{
      for (final t in formCapabilityTools(
        templatePort: port,
        rendererRegistry: standardRendererRegistry(
          embeddedFont: gothic,
          fallbackFonts: [gothic],
        ),
      ))
        t.verb: t,
    };
    await cjkTools['save_template']!.invoke({'template': template()});
    final created = (await cjkTools['create_document']!.invoke({
          'templateId': 'quote',
          'data': {'title': 'Localized quotation', 'total': '₩5,000,000'},
        }))!
        as Map<String, dynamic>;
    final rendered = (await cjkTools['render']!.invoke({
          'documentId': created['documentId'],
          'format': 'pdf',
        }))!
        as Map<String, dynamic>;
    final bytes = base64Decode(rendered['data'] as String);
    final pdfText = String.fromCharCodes(bytes);
    expect(pdfText, startsWith('%PDF'));
    expect(
      pdfText,
      contains('FontFile2'),
      reason: 'the injected TrueType must be embedded (Type0 subset)',
    );
  });
}
