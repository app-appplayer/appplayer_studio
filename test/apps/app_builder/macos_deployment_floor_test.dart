/// A generated native app scaffolded by `flutter create` targets macOS
/// 10.15, below what the current Xcode builds; the floor raises the Runner
/// project, the Podfile platform and every pod target.
library;

import 'dart:io';

import 'package:appplayer_studio/src/apps/app_builder/infra/macos_deployment_floor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('macos_floor_');
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> write(String rel, String body) async {
    final f = File(p.join(tmp.path, rel));
    await f.parent.create(recursive: true);
    return f.writeAsString(body);
  }

  test('no macos folder — nothing to do', () async {
    expect(await applyMacosDeploymentFloor(tmp.path), isEmpty);
  });

  test('raises the Runner targets and writes a floored Podfile', () async {
    final pbx = await write(
      'macos/Runner.xcodeproj/project.pbxproj',
      'MACOSX_DEPLOYMENT_TARGET = 10.15;\nMACOSX_DEPLOYMENT_TARGET = 10.15;\n',
    );
    final changed = await applyMacosDeploymentFloor(tmp.path);
    expect(changed, hasLength(2));
    expect(await pbx.readAsString(), isNot(contains('10.15')));
    expect(
      RegExp(
        'MACOSX_DEPLOYMENT_TARGET = 12.0;',
      ).allMatches(await pbx.readAsString()),
      hasLength(2),
    );
    final podfile =
        await File(p.join(tmp.path, 'macos', 'Podfile')).readAsString();
    expect(podfile, startsWith("platform :osx, '12.0'"));
    expect(
      podfile,
      contains("config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '12.0'"),
    );
    expect(podfile, contains('flutter_install_all_macos_pods'));
  });

  test('patches an existing Podfile once; a higher target is kept', () async {
    await write(
      'macos/Runner.xcodeproj/project.pbxproj',
      'MACOSX_DEPLOYMENT_TARGET = 14.0;\n',
    );
    final pod = await write(
      'macos/Podfile',
      "platform :osx, '10.15'\n\npost_install do |installer|\n"
          '  installer.pods_project.targets.each do |target|\n'
          '    flutter_additional_macos_build_settings(target)\n'
          '  end\nend\n',
    );
    await applyMacosDeploymentFloor(tmp.path);
    final once = await pod.readAsString();
    expect(once, contains("platform :osx, '12.0'"));
    expect(
      "config.build_settings['MACOSX_DEPLOYMENT_TARGET']"
          .allMatches(once)
          .length,
      1,
    );
    // Idempotent, and 14.0 is above the floor.
    expect(await applyMacosDeploymentFloor(tmp.path), isEmpty);
    expect(
      await File(
        p.join(tmp.path, 'macos', 'Runner.xcodeproj', 'project.pbxproj'),
      ).readAsString(),
      contains('14.0'),
    );
  });
}
