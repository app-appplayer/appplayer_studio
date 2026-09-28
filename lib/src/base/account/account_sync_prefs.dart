/// This installation's account sync facts: its device id and whether it takes
/// part.
///
/// Kept in its own file (`<configRoot>/account_sync.json`) rather than in
/// `settings.json`: the Settings dialog saves the whole settings document from
/// the copy it opened with, so a switch flipped inside that dialog would be
/// written back to its old value on Save. These two values are the device's,
/// not dialog fields.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

class AccountSyncPrefs {
  AccountSyncPrefs._(
    this._file, {
    required this.deviceId,
    required bool syncEnabled,
  }) : _syncEnabled = syncEnabled;

  final File _file;

  /// This installation's stable id — the `device/<deviceId>` scope. Made
  /// once and kept.
  final String deviceId;

  bool _syncEnabled;

  /// Whether this device sends and receives account state (platform spec 20
  /// §5). Off until the person turns it on.
  bool get syncEnabled => _syncEnabled;

  static String pathIn(String configRoot) =>
      p.join(configRoot, 'account_sync.json');

  /// Reads the file under [configRoot], creating the device id (and the file)
  /// the first time. An unreadable file is treated as absent — a new id is
  /// better than a device that cannot declare itself.
  static AccountSyncPrefs loadOrCreate(String configRoot) {
    final file = File(pathIn(configRoot));
    String? id;
    var enabled = false;
    try {
      if (file.existsSync()) {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is Map) {
          final stored = raw['deviceId'];
          if (stored is String && stored.isNotEmpty) id = stored;
          enabled = raw['syncEnabled'] == true;
        }
      }
    } catch (_) {
      id = null;
      enabled = false;
    }
    final prefs = AccountSyncPrefs._(
      file,
      deviceId: id ?? newDeviceId(),
      syncEnabled: enabled,
    );
    if (id == null) prefs._write();
    return prefs;
  }

  /// A random 32-hex-digit id.
  static String newDeviceId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void setSyncEnabled(bool enabled) {
    _syncEnabled = enabled;
    _write();
  }

  void _write() {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.$pid.tmp');
    tmp.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'deviceId': deviceId,
        'syncEnabled': _syncEnabled,
      }),
    );
    tmp.renameSync(_file.path);
  }
}
