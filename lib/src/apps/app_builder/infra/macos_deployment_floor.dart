/// macOS deployment floor for generated native apps.
///
/// Xcode 27 builds macOS 12.0 and later only, while `flutter create`
/// scaffolds `MACOSX_DEPLOYMENT_TARGET = 10.15` and Flutter writes its
/// CocoaPods Podfile with `platform :osx, '10.15'` on the first build — so a
/// freshly scaffolded app did not build. The studio's own `macos/` carries
/// the same floor (its Podfile `post_install`); this applies it to the apps
/// it generates, right after `flutter create`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Lowest macOS version the current Xcode builds for.
const String kMacosDeploymentFloor = '12.0';

/// Raise the scaffolded macOS project in [outDir] to [kMacosDeploymentFloor]:
/// the Runner targets, the Podfile `platform`, and every pod target (a
/// `post_install` setting — pods otherwise keep their own lower floor).
/// No-op when [outDir] has no `macos/`. Returns the files it changed.
Future<List<String>> applyMacosDeploymentFloor(String outDir) async {
  final macos = Directory(p.join(outDir, 'macos'));
  if (!await macos.exists()) return const <String>[];
  final changed = <String>[];

  final pbxproj = File(
    p.join(macos.path, 'Runner.xcodeproj', 'project.pbxproj'),
  );
  if (await pbxproj.exists()) {
    final src = await pbxproj.readAsString();
    final out = src.replaceAllMapped(
      RegExp(r'MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);'),
      (m) =>
          _below(m.group(1)!)
              ? 'MACOSX_DEPLOYMENT_TARGET = $kMacosDeploymentFloor;'
              : m.group(0)!,
    );
    if (out != src) {
      await pbxproj.writeAsString(out);
      changed.add(pbxproj.path);
    }
  }

  final podfile = File(p.join(macos.path, 'Podfile'));
  if (!await podfile.exists()) {
    // Written before Flutter would generate its own (on the first build with
    // a plugin); Flutter keeps an existing Podfile.
    await podfile.writeAsString(_podfile);
    changed.add(podfile.path);
  } else {
    final src = await podfile.readAsString();
    var out = src.replaceAllMapped(
      RegExp(r"platform :osx, '([0-9.]+)'"),
      (m) =>
          _below(m.group(1)!)
              ? "platform :osx, '$kMacosDeploymentFloor'"
              : m.group(0)!,
    );
    if (!out.contains("config.build_settings['MACOSX_DEPLOYMENT_TARGET']")) {
      out = out.replaceFirst(
        '    flutter_additional_macos_build_settings(target)\n',
        '    flutter_additional_macos_build_settings(target)\n$_podFloor',
      );
    }
    if (out != src) {
      await podfile.writeAsString(out);
      changed.add(podfile.path);
    }
  }
  return changed;
}

bool _below(String version) {
  final have = version.split('.').map(int.tryParse).toList();
  final floor = kMacosDeploymentFloor.split('.').map(int.parse).toList();
  for (var i = 0; i < floor.length; i++) {
    final v = i < have.length ? (have[i] ?? 0) : 0;
    if (v != floor[i]) return v < floor[i];
  }
  return false;
}

const String _podFloor =
    '    target.build_configurations.each do |config|\n'
    "      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = "
    "'$kMacosDeploymentFloor'\n"
    '    end\n';

/// Flutter's macOS Podfile template with the floor applied.
const String _podfile =
    "platform :osx, '$kMacosDeploymentFloor'\n"
    '\n'
    '# CocoaPods analytics sends network stats synchronously affecting '
    'flutter build latency.\n'
    "ENV['COCOAPODS_DISABLE_STATS'] = 'true'\n"
    '\n'
    "project 'Runner', {\n"
    "  'Debug' => :debug,\n"
    "  'Profile' => :release,\n"
    "  'Release' => :release,\n"
    '}\n'
    '\n'
    'def flutter_root\n'
    "  generated_xcode_build_settings_path = File.expand_path(File.join('..', "
    "'Flutter', 'ephemeral', 'Flutter-Generated.xcconfig'), __FILE__)\n"
    '  unless File.exist?(generated_xcode_build_settings_path)\n'
    '    raise "#{generated_xcode_build_settings_path} must exist. If you\'re '
    'running pod install manually, make sure \\"flutter pub get\\" is executed '
    'first"\n'
    '  end\n'
    '\n'
    '  File.foreach(generated_xcode_build_settings_path) do |line|\n'
    r'    matches = line.match(/FLUTTER_ROOT\=(.*)/)'
    '\n'
    '    return matches[1].strip if matches\n'
    '  end\n'
    '  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. '
    'Try deleting Flutter-Generated.xcconfig, then run \\"flutter pub get\\""\n'
    'end\n'
    '\n'
    "require File.expand_path(File.join('packages', 'flutter_tools', 'bin', "
    "'podhelper'), flutter_root)\n"
    '\n'
    'flutter_macos_podfile_setup\n'
    '\n'
    "target 'Runner' do\n"
    '  use_frameworks!\n'
    '\n'
    '  flutter_install_all_macos_pods File.dirname(File.realpath(__FILE__))\n'
    "  target 'RunnerTests' do\n"
    '    inherit! :search_paths\n'
    '  end\n'
    'end\n'
    '\n'
    'post_install do |installer|\n'
    '  installer.pods_project.targets.each do |target|\n'
    '    flutter_additional_macos_build_settings(target)\n'
    '$_podFloor'
    '  end\n'
    'end\n';
