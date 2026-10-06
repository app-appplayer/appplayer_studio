import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String dir;

  void write(String rel, Object content) {
    final f = File(p.join(dir, rel))..parent.createSync(recursive: true);
    f.writeAsStringSync(content is String ? content : jsonEncode(content));
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('self_names_');
    dir = p.join(tmp.path, 'kanban.mbd');
    write('manifest.json', <String, dynamic>{
      'manifest': <String, dynamic>{'id': 'com.acme.kanban', 'version': '1'},
      'tools': <String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'board.summary', 'kind': 'js'},
          <String, dynamic>{'name': 'kanban.save', 'kind': 'js'},
        ],
      },
      'wiring': <String, dynamic>{
        'lifecycle': <Map<String, dynamic>>[
          <String, dynamic>{'slot': 'project.save', 'tool': 'kanban.save'},
          <String, dynamic>{'slot': 'project.open', 'tool': 'studio.fs.read'},
        ],
        'domainActions': <Map<String, dynamic>>[
          // A host tool that shares the prefix is not the bundle's own.
          <String, dynamic>{'tool': 'kanban.export_all'},
        ],
      },
      'agents': <String, dynamic>{
        'agents': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'manager',
            'tools': <String>['com.acme.kanban.board.*', 'bk.fact.*'],
          },
        ],
      },
    });
    write('ui/pages/main.json', <String, dynamic>{
      'type': 'page',
      'content': <String, dynamic>{
        'type': 'button',
        'click': <String, dynamic>{
          'type': 'tool',
          'tool': 'kanban.board.summary',
        },
      },
    });
    write(
      'tools/board.js',
      'async function summary(a) { return host.mcp.callTool("board.summary", {}); }\n'
          'async function all(a) { return host.mcp.callTool(\'kanban.board.summary\', {}); }\n',
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('reports every id-prefixed name of an own tool, nothing else', () {
    final found = selfNamedToolReferences(dir).map((r) => '$r').toList();
    expect(found, <String>[
      'manifest.json: "kanban.save" carries this bundle\'s id — write "save" '
          '(the host adds the id)',
      'manifest.json: "kanban.save" carries this bundle\'s id — write "save" '
          '(the host adds the id)',
      'manifest.json: "com.acme.kanban.board.*" carries this bundle\'s id — '
          'write "board.*" (the host adds the id)',
      'ui/pages/main.json: "kanban.board.summary" carries this bundle\'s id '
          '— write "board.summary" (the host adds the id)',
      'tools/board.js: "kanban.board.summary" carries this bundle\'s id — '
          'write "board.summary" (the host adds the id)',
    ]);
  });

  test(
    'export refuses a bundle that names its own tools with its id',
    () async {
      final boot = mk.InProcessKernelServerHost();
      registerProjectTools(boot, ChromeBridge(), toolId: 'self_names_test');
      final refused = await boot.callTool('studio.project.export', {
        'bundlePath': dir,
        'target': p.join(tmp.path, 'out.mcpb'),
      });
      expect(refused.isError, isTrue);
      final body =
          jsonDecode((refused.content.single as mk.KernelTextContent).text)
              as Map<String, dynamic>;
      expect(body['issues'], hasLength(5));
      expect(File(p.join(tmp.path, 'out.mcpb')).existsSync(), isFalse);
    },
  );
}
